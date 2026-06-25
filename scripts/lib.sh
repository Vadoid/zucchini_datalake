#!/usr/bin/env bash
# Shared helpers for the staged POC runner. Sourced by every stage script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
SQL_DIR="$ROOT/sql"

# --- pretty output ---------------------------------------------------------
c_blue='\033[1;34m'; c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_off='\033[0m'
say()   { echo -e "${c_blue}==>${c_off} $*"; }
ok()    { echo -e "${c_grn}OK ${c_off} $*"; }
warn()  { echo -e "${c_yel}!! ${c_off} $*"; }
die()   { echo -e "${c_red}XX ${c_off} $*" >&2; exit 1; }
pause() { echo; read -r -p "$(echo -e "${c_yel}-- press ENTER to continue --${c_off}")" _; echo; }

# --- prerequisites ---------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
check_tools() { need terraform; need gcloud; need bq; need psql; }

# --- terraform helpers -----------------------------------------------------
tfout() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

tf_apply() { # tf_apply <target> [<target> ...]
  local args=()
  for t in "$@"; do args+=(-target="$t"); done
  say "terraform apply ${args[*]:-(everything)}"
  terraform -chdir="$TF_DIR" apply -auto-approve "${args[@]}"
}

# Password comes from terraform.tfvars (alloydb_password) or env override.
load_password() {
  if [[ -n "${ALLOYDB_PASSWORD:-}" ]]; then return; fi
  local f="$TF_DIR/terraform.tfvars"
  [[ -f "$f" ]] || die "terraform.tfvars not found and ALLOYDB_PASSWORD unset"
  ALLOYDB_PASSWORD="$(grep -E '^\s*alloydb_password' "$f" | sed -E 's/.*=\s*"(.*)"\s*$/\1/')"
  [[ -n "$ALLOYDB_PASSWORD" ]] || die "could not read alloydb_password from tfvars"
  export ALLOYDB_PASSWORD
}

# Load common config from terraform outputs (after stage 1 has applied).
load_cfg() {
  PROJECT="$(tfout project_id)"   || die "no terraform outputs yet — run 01 first"
  REGION="$(tfout region)"
  ZONE="$(tfout zone)"
  PROXY="$(tfout proxy_vm_name)"
  [[ -n "${PROJECT:-}" ]] || die "empty project output"
  export PROJECT REGION ZONE PROXY
}

# --- IAP tunnel to AlloyDB (proxy VM socat-forwards 5432 -> AlloyDB) --------
PGLOCAL_PORT=5432
TUNNEL_PID=""

start_tunnel() {
  load_cfg
  say "opening IAP tunnel localhost:${PGLOCAL_PORT} -> ${PROXY}:5432 (-> AlloyDB)"
  gcloud compute start-iap-tunnel "$PROXY" 5432 \
    --local-host-port="localhost:${PGLOCAL_PORT}" \
    --zone="$ZONE" --project="$PROJECT" >/tmp/iap_tunnel.log 2>&1 &
  TUNNEL_PID=$!
  trap stop_tunnel EXIT
  # wait until the local port answers
  for _ in $(seq 1 30); do
    if (echo >/dev/tcp/localhost/${PGLOCAL_PORT}) >/dev/null 2>&1; then ok "tunnel up"; return; fi
    sleep 1
  done
  cat /tmp/iap_tunnel.log >&2; die "tunnel did not come up"
}

stop_tunnel() {
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" >/dev/null 2>&1 || true
  TUNNEL_PID=""
}

# --- psql / bq wrappers ----------------------------------------------------
psqlt() { # psqlt <db> -- runs SQL from stdin or via extra args
  load_password
  PGPASSWORD="$ALLOYDB_PASSWORD" psql \
    "host=localhost port=${PGLOCAL_PORT} user=postgres dbname=$1 sslmode=disable" \
    "${@:2}"
}

bqq() { # bqq "<SQL>"
  load_cfg
  bq --project_id="$PROJECT" query --use_legacy_sql=false --format=pretty "$1"
}
