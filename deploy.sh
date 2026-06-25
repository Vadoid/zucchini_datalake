#!/usr/bin/env bash
# deploy.sh — single entrypoint for the zucchini_datalake POC.
# Configures Terraform vars from flags/env, then orchestrates the staged scripts.
#
# Usage:
#   ./deploy.sh [options] [command]
#
# Commands (default: all):
#   all          run every stage in order (provision -> check -> demo)
#   alloydb      stage 1 only
#   function     stage 2 only
#   datastream   stage 3 only
#   bq           stage 4 only
#   demo         stage 5 only (views + live streaming demo)
#   stream X     control streaming: X = start|stop|once|status
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
#   --password PW           AlloyDB/datastream password       [TF_VAR_alloydb_password]
#   --create-project        create the project (needs billing + org/folder)
#   --billing-account ID                                       [TF_VAR_billing_account]
#   --org-id ID             (mutually exclusive with folder)   [TF_VAR_org_id]
#   --folder-id ID                                             [TF_VAR_folder_id]
#   --iters N               demo observation rounds (default 5)
#   --gap S                 demo seconds between rounds (default 90)
#   --yes                   non-interactive (no pauses between stages)
#   --no-write-tfvars       do not (re)generate terraform.tfvars; use existing
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
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "--config" ]]; then j=$((i+1)); CONFIG="${!j}"; fi
done
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required to read config.json"; exit 1; }
cfg() { [[ -f "$CONFIG" ]] && jq -r --arg k "$1" '.[$k] // empty' "$CONFIG" 2>/dev/null || true; }

# --- defaults (TF_VAR_* env > config.json > literal) ------------------------
PROJECT="${TF_VAR_project_id:-$(cfg project_id)}"
REGION="${TF_VAR_region:-$(cfg region)}";       REGION="${REGION:-us-central1}"
ZONE="${TF_VAR_zone:-$(cfg zone)}";             ZONE="${ZONE:-us-central1-a}"
PASSWORD="${TF_VAR_alloydb_password:-$(cfg alloydb_password)}"
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
    --create-project)   CREATE_PROJECT=true; shift;;
    --billing-account)  BILLING="$2"; shift 2;;
    --org-id)           ORG_ID="$2"; shift 2;;
    --folder-id)        FOLDER_ID="$2"; shift 2;;
    --iters)            ITERS="$2"; shift 2;;
    --gap)              GAP="$2"; shift 2;;
    --yes|-y)           YES=1; shift;;
    --no-write-tfvars)  WRITE_TFVARS=0; shift;;
    -h|--help)          sed -n '2,40p' "$0"; exit 0;;
    all|alloydb|function|datastream|bq|demo|plan|output|destroy)
                        CMD="$1"; shift;;
    stream)             CMD="stream"; STREAM_ACTION="${2:-status}"; shift 2 || shift;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

# --- write terraform.tfvars from the resolved config -----------------------
gen_tfvars() {
  local f="$TF_DIR/terraform.tfvars"
  [[ -n "$PROJECT" ]]  || { echo "ERROR: --project is required (or set TF_VAR_project_id)"; exit 1; }
  [[ -n "$PASSWORD" ]] || { echo "ERROR: --password is required (or set TF_VAR_alloydb_password)"; exit 1; }
  {
    echo "# generated by deploy.sh — do not edit by hand"
    echo "project_id       = \"$PROJECT\""
    echo "region           = \"$REGION\""
    echo "zone             = \"$ZONE\""
    echo "create_project   = $CREATE_PROJECT"
    echo "alloydb_password = \"$PASSWORD\""
    [[ -n "$BILLING"   ]] && echo "billing_account  = \"$BILLING\""
    [[ -n "$ORG_ID"    ]] && echo "org_id           = \"$ORG_ID\""
    [[ -n "$FOLDER_ID" ]] && echo "folder_id        = \"$FOLDER_ID\""
  } > "$f"
  echo "wrote $f"
}

# Stage scripts read the password from tfvars; export for non-tfvars runs too.
export ALLOYDB_PASSWORD="${PASSWORD:-${ALLOYDB_PASSWORD:-}}"

if [[ "$WRITE_TFVARS" == 1 && "$CMD" != "output" && "$CMD" != "stream" ]]; then
  gen_tfvars
fi

run_stage() { bash "$SCRIPTS/$1"; }

case "$CMD" in
  all)
    terraform -chdir="$TF_DIR" init -input=false >/dev/null
    if [[ "$YES" == 1 ]]; then
      run_stage 01_alloydb.sh
      run_stage 02_function.sh
      run_stage 03_datastream.sh
      run_stage 04_bq_iceberg.sh
      bash "$SCRIPTS/05_views_demo.sh" "$ITERS" "$GAP"
    else
      bash "$SCRIPTS/run_all.sh"
    fi
    ;;
  alloydb)    terraform -chdir="$TF_DIR" init -input=false >/dev/null; run_stage 01_alloydb.sh;;
  function)   run_stage 02_function.sh;;
  datastream) run_stage 03_datastream.sh;;
  bq)         run_stage 04_bq_iceberg.sh;;
  demo)       bash "$SCRIPTS/05_views_demo.sh" "$ITERS" "$GAP";;
  stream)     bash "$SCRIPTS/stream.sh" "${STREAM_ACTION:-status}";;
  plan)       terraform -chdir="$TF_DIR" init -input=false >/dev/null; terraform -chdir="$TF_DIR" plan;;
  output)     terraform -chdir="$TF_DIR" output;;
  destroy)    bash "$ROOT/destroy.sh";;
  *) echo "unknown command: $CMD" >&2; exit 1;;
esac
