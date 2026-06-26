#!/usr/bin/env bash
# deploy.sh — single entrypoint for the zucchini_datalake POC.
# Configures Terraform vars from flags/env, then orchestrates the staged scripts.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Commands (default: all):
#   all          full provision in one apply, then DB init + Datastream + load + demo:
#                  PHASE A  terraform apply (everything, stream gated off)
#                  DB INIT  schema + CDC publication/slot + seed (psql)
#                  PHASE B  terraform apply (enable Datastream stream)
#                  wait stream RUNNING, load bigquery_iceberg, build views, demo
#   demo         views + live streaming demo only
#   doctor       check required tools (terraform/gcloud/bq/psql/jq); print fixes
#   stream X     control streaming: X = start|stop|once|status
#   ui X         sync control panel (Cloud Run): X = deploy|url|delete
#   plan         terraform plan
#   output       show terraform outputs
#   destroy      tear everything down
#
# Base config comes from config.json (override path with --config PATH).
# Precedence per value: CLI flag > TF_VAR_* env > config.json > default.
#
# Options (override matching Terraform variable; also read from env TF_VAR_*):
#   --config PATH           config.json path (default ./config.json)
#   --project ID            (required for a fresh run)        [TF_VAR_project_id]
#   --region REGION         default us-central1               [TF_VAR_region]
#   --zone ZONE             default us-central1-a              [TF_VAR_zone]
#   --password PW           AlloyDB password. Optional: auto-generated into
#                           config.json when empty/placeholder. [TF_VAR_alloydb_password]
#   --authorized-cidr CIDR  IP allowed to psql AlloyDB public IP, e.g. 1.2.3.4/32
#                           (empty = no public IP)             [TF_VAR_alloydb_authorized_cidr]
#   --create-project        create the project (needs billing + org/folder)
#   --billing-account ID                                       [TF_VAR_billing_account]
#   --org-id ID             (mutually exclusive with folder)   [TF_VAR_org_id]
#   --folder-id ID                                             [TF_VAR_folder_id]
#   --iters N               demo observation rounds (default 5)
#   --gap S                 demo seconds between rounds (default 90)
#   --yes                   non-interactive: auto-yes to all confirmations
#   --install-deps          auto-install any missing tools via brew/apt (opt-in)
#   --no-write-tfvars       skip rendering terraform.auto.tfvars.json from config
#   -h | --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$ROOT/terraform"
SCRIPTS="$ROOT/scripts"

# --- logging: tee everything to a timestamped log in the repo root ---------
if [[ -z "${_DEPLOY_LOGGING:-}" ]]; then
  export _DEPLOY_LOGGING=1
  LOG="$ROOT/deploy-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  echo "# log: $LOG"
fi

# --- config.json (base config) ---------------------------------------------
# Precedence per value: CLI flag > TF_VAR_* env > config.json > built-in default.
# Override the config path with: --config PATH  or  CONFIG=PATH env.
CONFIG="${CONFIG:-$ROOT/config.json}"
INSTALL_DEPS=0
IS_DOCTOR=0
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--config" ]]; then j=$((i+1)); CONFIG="${!j}"; fi
  if [[ "${!i}" == "--install-deps" ]]; then export INSTALL_DEPS=1; INSTALL_DEPS=1; fi
  if [[ "${!i}" == "doctor" ]]; then IS_DOCTOR=1; fi
done

# If jq is missing, handle based on installation option and command
if ! command -v jq >/dev/null 2>&1; then
  if [[ "$INSTALL_DEPS" == 1 ]]; then
    echo "Installing jq (required to read config.json)..."
    if command -v brew >/dev/null 2>&1; then
      brew install jq
    elif command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update && sudo apt-get install -y jq
    else
      echo "ERROR: jq is required, and no package manager (brew/apt) was found to install it." >&2
      exit 1
    fi
  elif [[ "$IS_DOCTOR" == 1 ]]; then
    # Let doctor command proceed; it will report missing jq
    echo "Warning: jq is missing. Proceeding with doctor check..."
  else
    echo "ERROR: jq is required to read config.json." >&2
    if command -v apt-get >/dev/null 2>&1; then
      echo "Please install it manually (sudo apt-get install jq) or run: ./deploy.sh --install-deps" >&2
    elif command -v brew >/dev/null 2>&1; then
      echo "Please install it manually (brew install jq) or run: ./deploy.sh --install-deps" >&2
    fi
    exit 1
  fi
fi

cfg() {
  [[ -f "$CONFIG" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' "$CONFIG" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))" "$CONFIG" "$1" 2>/dev/null || true
  fi
}

# --- defaults (TF_VAR_* env > config.json > literal) ------------------------
PROJECT="${TF_VAR_project_id:-$(cfg project_id)}"
REGION="${TF_VAR_region:-$(cfg region)}";       REGION="${REGION:-us-central1}"
ZONE="${TF_VAR_zone:-$(cfg zone)}";             ZONE="${ZONE:-us-central1-a}"
PASSWORD="${TF_VAR_alloydb_password:-$(cfg alloydb_password)}"
AUTH_CIDR="${TF_VAR_alloydb_authorized_cidr:-$(cfg alloydb_authorized_cidr)}"
CREATE_PROJECT="${TF_VAR_create_project:-$(cfg create_project)}"; CREATE_PROJECT="${CREATE_PROJECT:-false}"
BILLING="${TF_VAR_billing_account:-$(cfg billing_account)}"
ORG_ID="${TF_VAR_org_id:-$(cfg org_id)}"
FOLDER_ID="${TF_VAR_folder_id:-$(cfg folder_id)}"
ITERS="$(cfg demo_iters)";  ITERS="${ITERS:-5}"
GAP="$(cfg demo_gap)";      GAP="${GAP:-90}"
YES=0
WRITE_TFVARS=1
CMD="all"

# --- arg parse -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           shift 2;;  # already consumed in pre-scan above
    --project)          PROJECT="$2"; shift 2;;
    --region)           REGION="$2"; shift 2;;
    --zone)             ZONE="$2"; shift 2;;
    --password)         PASSWORD="$2"; shift 2;;
    --authorized-cidr)  AUTH_CIDR="$2"; shift 2;;
    --create-project)   CREATE_PROJECT=true; shift;;
    --billing-account)  BILLING="$2"; shift 2;;
    --org-id)           ORG_ID="$2"; shift 2;;
    --folder-id)        FOLDER_ID="$2"; shift 2;;
    --iters)            ITERS="$2"; shift 2;;
    --gap)              GAP="$2"; shift 2;;
    --yes|-y)           YES=1; shift;;
    --no-write-tfvars)  WRITE_TFVARS=0; shift;;
    --install-deps)     export INSTALL_DEPS=1; shift;;
    -h|--help)          sed -n '2,44p' "$0"; exit 0;;
    all|demo|plan|output|destroy|doctor)
                        CMD="$1"; shift;;
    stream)             CMD="stream"; STREAM_ACTION="${2:-status}"; shift 2 || shift;;
    ui)                 CMD="ui"; UI_ACTION="${2:-deploy}"; shift 2 || shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# --- render Terraform vars from config.json (derived; never hand-edited) ----
# Written as an auto-loaded *.auto.tfvars.json so plain `terraform` works too.
gen_tfvars() {
  local f="$TF_DIR/terraform.auto.tfvars.json"
  [[ -n "$PROJECT" ]]  || { echo "ERROR: project_id missing (config.json or --project)"; exit 1; }
  [[ -n "$PASSWORD" ]] || { echo "ERROR: alloydb_password missing (config.json or --password)"; exit 1; }
  jq -n \
    --arg project_id "$PROJECT" --arg region "$REGION" --arg zone "$ZONE" \
    --argjson create_project "${CREATE_PROJECT:-false}" \
    --arg alloydb_password "$PASSWORD" --arg cidr "$AUTH_CIDR" \
    --arg billing "$BILLING" --arg org "$ORG_ID" --arg folder "$FOLDER_ID" '
    {project_id:$project_id, region:$region, zone:$zone,
     create_project:$create_project, alloydb_password:$alloydb_password}
    + (if $cidr    == "" then {} else {alloydb_authorized_cidr:$cidr} end)
    + (if $billing == "" then {} else {billing_account:$billing} end)
    + (if $org     == "" then {} else {org_id:$org} end)
    + (if $folder  == "" then {} else {folder_id:$folder} end)
  ' > "$f"
  echo "rendered $f from $(basename "$CONFIG")"
}

# Generate a password if none set / still the placeholder, and persist it to
# config.json (local, gitignored). One source of truth, nothing to type.
ensure_password() {
  if [[ -z "$PASSWORD" || "$PASSWORD" == CHANGE-ME* ]]; then
    # finite read (no early pipe close -> no SIGPIPE under pipefail); cut trims.
    PASSWORD="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-28)"
    if [[ -f "$CONFIG" ]]; then
      local tmp; tmp="$(mktemp)"
      jq --arg p "$PASSWORD" '.alloydb_password=$p' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
      echo "generated alloydb_password -> $(basename "$CONFIG")"
    else
      echo "generated alloydb_password (no config.json to persist to; using for this run)"
    fi
  fi
}

if [[ "$WRITE_TFVARS" == 1 && "$CMD" != "output" && "$CMD" != "stream" && "$CMD" != "doctor" ]]; then
  ensure_password
  gen_tfvars
fi

export ALLOYDB_PASSWORD="${PASSWORD:-${ALLOYDB_PASSWORD:-}}"

# Interactive yes/no (auto-yes with --yes). Returns 0 for yes.
confirm() {
  [[ "$YES" == 1 ]] && return 0
  local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy] ]]
}

# Show the resolved config and what is about to happen.
banner() {
  echo
  echo "  ┌───────────────────────────────────────────────────────────"
  echo "  │  zucchini_datalake  —  deploy"
  echo "  ├───────────────────────────────────────────────────────────"
  printf  "  │  project   : %s\n" "$PROJECT"
  printf  "  │  region    : %s   zone: %s\n" "$REGION" "$ZONE"
  printf  "  │  psql CIDR : %s\n" "${AUTH_CIDR:-<public IP disabled>}"
  printf  "  │  create    : %s\n" "$CREATE_PROJECT"
  printf  "  │  demo      : %s rounds, %ss apart\n" "$ITERS" "$GAP"
  echo "  ├───────────────────────────────────────────────────────────"
  echo "  │  A) terraform apply (all infra, stream off)"
  echo "  │  B) DB schema + CDC + seed"
  echo "  │  C) terraform apply (enable Datastream)"
  echo "  │  D) wait stream, load BigQuery Iceberg, build views, demo"
  echo "  └───────────────────────────────────────────────────────────"
  echo
}

# Closing summary: where everything landed + how to drive it.
summary() {
  echo
  echo "  ===================  DONE  ==================="
  TF output 2>/dev/null | sed 's/^/  /'
  echo
  echo "  datasets : alloydb_iceberg  bigquery_iceberg  common_layer"
  echo "  control  : ./deploy.sh stream start|stop|once|status"
  echo "  validate : bq query --use_legacy_sql=false < sql/06_bigquery_validate.sql"
  echo "  teardown : ./destroy.sh"
  echo "  ============================================="
}

# Fail fast on auth / missing project BEFORE terraform starts creating things.
preflight() {
  echo "== preflight: gcloud auth + project =="
  command -v gcloud >/dev/null 2>&1 || { echo "ERROR: gcloud missing (./deploy.sh doctor)"; exit 1; }

  # User credentials (used by gcloud/bq). Re-login if expired.
  if ! gcloud auth print-access-token >/dev/null 2>&1; then
    echo "gcloud user credentials missing/expired -> launching login..."
    gcloud auth login || { echo "ERROR: gcloud auth login failed"; exit 1; }
  fi

  # Project must exist (unless Terraform is creating it).
  if [[ "${CREATE_PROJECT}" != "true" ]]; then
    if ! gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
      echo "ERROR: project '$PROJECT' not found or not accessible."
      echo "  fix one of:"
      echo "    - set an existing project in config.json (project_id)"
      echo "    - set create_project=true + billing_account + org_id/folder_id"
      exit 1
    fi
  fi

  # Application Default Credentials (used by Terraform). A cached token can still
  # fail org reauth (invalid_rapt) on sensitive APIs, so EXERCISE serviceusage
  # with the ADC token rather than just printing it. Re-login on failure.
  local adc_token rc=1
  adc_token="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
  if [[ -n "$adc_token" && "${CREATE_PROJECT}" != "true" ]]; then
    curl -fsS -o /dev/null -H "Authorization: Bearer $adc_token" \
      "https://serviceusage.googleapis.com/v1/projects/${PROJECT}/services?pageSize=1" 2>/dev/null && rc=0
  elif [[ -n "$adc_token" ]]; then
    rc=0  # creating the project; can't probe serviceusage yet
  fi
  if [[ "$rc" != 0 ]]; then
    echo "ADC missing or failing org reauth (invalid_rapt) -> launching ADC login..."
    gcloud auth application-default login || { echo "ERROR: ADC login failed"; exit 1; }
  fi

  echo "preflight ok: auth valid, project '$PROJECT' reachable, ADC accepted by serviceusage"
}

# Run preflight for any command that talks to GCP / Terraform.
case "$CMD" in
  all|demo|plan) preflight;;
esac

TF() { terraform -chdir="$TF_DIR" "$@"; }

# Apply the WHOLE config in one shot; enable_stream gates only the Datastream stream.
# Terraform's verbose output goes to a background log; the terminal shows only a
# compact progress line (resources done + elapsed). Full log path is printed.
apply_phase() {
  local es="$1"
  local logf="$ROOT/tf-apply-${es}.log"
  local t0=$SECONDS pid n rc
  say "terraform apply (enable_stream=$es) -> log: $(basename "$logf")"
  TF apply -auto-approve -var="enable_stream=$es" >"$logf" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    n="$(grep -c 'Creation complete' "$logf" 2>/dev/null || echo 0)"
    printf "   …applying: %s resources done, %ss elapsed\n" "$n" "$((SECONDS - t0))"
    sleep 15
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  n="$(grep -c 'Creation complete' "$logf" 2>/dev/null || echo 0)"
  if [[ $rc -ne 0 ]]; then
    warn "terraform apply failed (rc=$rc). Last 30 log lines:"
    tail -30 "$logf"
    die "see full log: $logf"
  fi
  ok "apply complete: $n resources created/updated in $((SECONDS - t0))s"
}

# Schema + CDC publication/slot + seed, run from your laptop over the public IP.
db_init() {
  wait_for_db
  say "create database tpcds (if absent)"
  psqlt postgres -tAc "SELECT 1 FROM pg_database WHERE datname='tpcds'" | grep -q 1 \
    || psqlt postgres -c "CREATE DATABASE tpcds;"
  say "schema";  psqlt tpcds -f "$SQL_DIR/01_alloydb_schema.sql"
  say "CDC publication + replication role"
  load_password
  local tmp; tmp="$(mktemp)"
  sed "s/change-me-strong-password/${ALLOYDB_PASSWORD}/g" "$SQL_DIR/03_alloydb_cdc_setup.sql" > "$tmp"
  psqlt tpcds -f "$tmp"; rm -f "$tmp"
  # The slot must be created by a REPLICATION role; AlloyDB's postgres user is not
  # one, but datastream_user is. Create it as that role (idempotent).
  say "replication slot (as datastream_user)"
  PGPASSWORD="$ALLOYDB_PASSWORD" psql "host=${ALLOYDB_PUB} port=5432 user=datastream_user dbname=tpcds sslmode=require" -tAc \
    "SELECT pg_create_logical_replication_slot('datalake_slot','pgoutput') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='datalake_slot');" || true
  say "seed";    psqlt tpcds -f "$SQL_DIR/02_alloydb_seed.sql"
  say "CHECK — AlloyDB row counts"
  psqlt tpcds -c "SELECT 'store_sales' t,count(*) n FROM store_sales
                  UNION ALL SELECT 'customer',count(*) FROM customer
                  UNION ALL SELECT 'item',count(*) FROM item
                  UNION ALL SELECT 'date_dim',count(*) FROM date_dim
                  UNION ALL SELECT 'store',count(*) FROM store ORDER BY t;"
}

wait_stream() {
  load_cfg
  local sid st n; sid="$(tfout stream_id)"
  say "waiting for Datastream '$sid' to reach RUNNING"
  for _ in $(seq 1 30); do
    st="$(gcloud datastream streams describe "$sid" --location="$REGION" --project="$PROJECT" --format='value(state)' 2>/dev/null || true)"
    echo "   state=$st"; [[ "$st" == RUNNING ]] && break
    [[ "$st" == FAILED ]] && die "stream FAILED — check publication/slot/network attachment"
    sleep 10
  done
  say "waiting for Iceberg tables to backfill into alloydb_iceberg"
  for _ in $(seq 1 30); do
    n="$(bq --project_id="$PROJECT" ls --max_results=50 alloydb_iceberg 2>/dev/null | grep -c TABLE || true)"
    echo "   tables=${n:-0}"; [[ "${n:-0}" -ge 5 ]] && break; sleep 15
  done
  bq --project_id="$PROJECT" ls alloydb_iceberg || true
}

bq_load() {
  load_cfg
  say "one-off load into bigquery_iceberg"
  bq --project_id="$PROJECT" query --use_legacy_sql=false < "$SQL_DIR/04_bigquery_iceberg_load.sql"
}

case "$CMD" in
  doctor)  source "$SCRIPTS/lib.sh"; check_tools && ok "all required tools present";;

  all)
    source "$SCRIPTS/lib.sh"; check_tools
    banner
    confirm "Provision this stack now?" || die "aborted by user"

    TF init -input=false >/dev/null
    say "PHASE A — provision ALL infra (Datastream stream off)"
    apply_phase false

    say "DB INIT — schema, CDC publication/slot, seed"
    db_init

    say "PHASE B — enable Datastream stream (publication now exists)"
    apply_phase true

    wait_stream
    bq_load

    if confirm "Run the live streaming demo now ($ITERS rounds, ${GAP}s apart)?"; then
      bash "$SCRIPTS/05_views_demo.sh" "$ITERS" "$GAP"
    else
      say "skipping demo — building views only"
      bq --project_id="$PROJECT" query --use_legacy_sql=false < "$SQL_DIR/05_common_layer_views.sql"
    fi

    summary
    ;;

  demo)    bash "$SCRIPTS/05_views_demo.sh" "$ITERS" "$GAP";;
  stream)  bash "$SCRIPTS/stream.sh" "${STREAM_ACTION:-status}";;
  ui)      bash "$SCRIPTS/ui.sh" "${UI_ACTION:-deploy}";;
  plan)    TF init -input=false >/dev/null; TF plan;;
  output)  TF output;;
  destroy) bash "$ROOT/destroy.sh";;
  *) echo "unknown command: $CMD" >&2; exit 1;;
esac
