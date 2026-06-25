#!/usr/bin/env bash
# Shared helpers for the staged POC runner. Sourced by every stage script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
SQL_DIR="$ROOT/sql"
CONFIG="${CONFIG:-$ROOT/config.json}"   # single source of truth

# Read a key from config.json (empty if missing).
cfg() { command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG" ]] && jq -r --arg k "$1" '.[$k] // empty' "$CONFIG" 2>/dev/null || true; }

# --- pretty output ---------------------------------------------------------
c_blue='\033[1;34m'; c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_off='\033[0m'
say()   { echo -e "${c_blue}==>${c_off} $*"; }
ok()    { echo -e "${c_grn}OK ${c_off} $*"; }
warn()  { echo -e "${c_yel}!! ${c_off} $*"; }
die()   { echo -e "${c_red}XX ${c_off} $*" >&2; exit 1; }
pause() { echo; read -r -p "$(echo -e "${c_yel}-- press ENTER to continue --${c_off}")" _; echo; }

# --- prerequisites ---------------------------------------------------------
REQUIRED_TOOLS=(terraform gcloud bq psql jq)

# Per-tool install command for the current package manager.
install_hint() {
  local t="$1" mgr="$2"
  case "$mgr:$t" in
    brew:terraform) echo "brew install terraform";;
    brew:gcloud|brew:bq) echo "brew install --cask google-cloud-sdk";;
    brew:psql) echo "brew install libpq && brew link --force libpq";;
    brew:jq) echo "brew install jq";;
    apt:terraform) echo "sudo apt-get install -y terraform   # needs HashiCorp apt repo";;
    apt:gcloud|apt:bq) echo "sudo apt-get install -y google-cloud-cli";;
    apt:psql) echo "sudo apt-get install -y postgresql-client";;
    apt:jq) echo "sudo apt-get install -y jq";;
    *) echo "install '$t' manually";;
  esac
}

pkg_mgr() {
  if command -v brew >/dev/null 2>&1; then echo brew
  elif command -v apt-get >/dev/null 2>&1; then echo apt
  else echo none; fi
}

# Opt-in installer (INSTALL_DEPS=1). Runs the hint commands for missing tools.
install_deps() {
  local mgr; mgr="$(pkg_mgr)"
  [[ "$mgr" == none ]] && die "no supported package manager (brew/apt) for auto-install"
  local done_gcloud=0
  for t in "$@"; do
    case "$t" in
      gcloud|bq) [[ "$done_gcloud" == 1 ]] && continue; done_gcloud=1;;
    esac
    say "installing $t"
    eval "$(install_hint "$t" "$mgr")"
  done
}

check_tools() {
  local missing=() t
  for t in "${REQUIRED_TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  ((${#missing[@]} == 0)) && return 0

  warn "missing tools: ${missing[*]}"
  if [[ "${INSTALL_DEPS:-0}" == 1 ]]; then
    install_deps "${missing[@]}"
    # re-check after install
    missing=(); for t in "${REQUIRED_TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    ((${#missing[@]} == 0)) && { ok "all tools present"; return 0; }
    die "still missing after install: ${missing[*]}"
  fi

  local mgr; mgr="$(pkg_mgr)"
  echo "install with:"
  for t in "${missing[@]}"; do echo "  $(install_hint "$t" "$mgr")"; done
  die "install the tools above, or re-run with: ./deploy.sh --install-deps <cmd>"
}

# --- terraform helpers -----------------------------------------------------
tfout() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

tf_apply() { # tf_apply <target> [<target> ...]
  local args=()
  for t in "$@"; do args+=(-target="$t"); done
  say "terraform apply ${args[*]:-(everything)}"
  terraform -chdir="$TF_DIR" apply -auto-approve "${args[@]}"
}

# Password comes from config.json (alloydb_password) or env override.
load_password() {
  if [[ -n "${ALLOYDB_PASSWORD:-}" ]]; then return; fi
  ALLOYDB_PASSWORD="$(cfg alloydb_password)"
  [[ -n "$ALLOYDB_PASSWORD" ]] || die "alloydb_password not in config.json and ALLOYDB_PASSWORD unset"
  export ALLOYDB_PASSWORD
}

# Load common config from terraform outputs (after stage 1 has applied).
load_cfg() {
  PROJECT="$(tfout project_id)"   || die "no terraform outputs yet — run 01 first"
  REGION="$(tfout region)"
  ZONE="$(tfout zone)"
  [[ -n "${PROJECT:-}" ]] || die "empty project output"
  export PROJECT REGION ZONE
}

# Resolve the AlloyDB public IP for psql sessions (requires alloydb_authorized_cidr set).
alloydb_host() {
  ALLOYDB_PUB="$(tfout alloydb_public_ip)"
  [[ -n "${ALLOYDB_PUB:-}" ]] || die "no AlloyDB public IP — set alloydb_authorized_cidr (e.g. YOUR.IP/32) and re-apply stage 1"
  export ALLOYDB_PUB
}

# Block until AlloyDB accepts connections (public IP can lag instance creation).
wait_for_db() {
  alloydb_host
  load_password
  say "waiting for AlloyDB to accept connections at $ALLOYDB_PUB"
  local i
  for i in $(seq 1 36); do
    if PGPASSWORD="$ALLOYDB_PASSWORD" PGCONNECT_TIMEOUT=5 psql \
        "host=$ALLOYDB_PUB port=5432 user=postgres dbname=postgres sslmode=require" \
        -tAc 'select 1' >/dev/null 2>&1; then
      ok "AlloyDB reachable"; return 0
    fi
    sleep 5
  done
  die "AlloyDB not reachable after ~3min (check public IP / firewall / password)"
}

# --- psql / bq wrappers ----------------------------------------------------
psqlt() { # psqlt <db> [psql args] -- direct to AlloyDB public IP over SSL
  load_password
  [[ -n "${ALLOYDB_PUB:-}" ]] || alloydb_host
  PGPASSWORD="$ALLOYDB_PASSWORD" psql \
    "host=${ALLOYDB_PUB} port=5432 user=postgres dbname=$1 sslmode=require" \
    "${@:2}"
}

bqq() { # bqq "<SQL>"
  load_cfg
  bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "$1"
}
