#!/usr/bin/env bash
# destroy.sh — tear down EVERYTHING for the zucchini_datalake POC.
#
# Handles the ordering traps a bare `terraform destroy` hits:
#   - the alloydb_iceberg dataset holds Datastream-created tables that Terraform
#     does not manage; the dataset won't delete until they're removed.
#   - the running stream / scheduler are stopped first.
#
# Usage:
#   ./destroy.sh [options]
#
# Options:
#   --project ID        project to target (else read from terraform output / config.json)
#   --region REGION     default from terraform output
#   --delete-project    skip terraform; delete the WHOLE GCP project (fastest,
#                       only sensible when deploy created it with --create-project)
#   --yes               no confirmation prompt
#   -h | --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$ROOT/terraform"
source "$ROOT/scripts/lib.sh"

# --- logging: tee everything to a timestamped log in the repo root ---------
if [[ -z "${_DESTROY_LOGGING:-}" ]]; then
  export _DESTROY_LOGGING=1
  LOG="$ROOT/destroy-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
  echo "# log: $LOG"
fi

CONFIG="${CONFIG:-$ROOT/config.json}"
PROJECT_FLAG=""; REGION_FLAG=""; DELETE_PROJECT=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)         CONFIG="$2"; shift 2;;
    --project)        PROJECT_FLAG="$2"; shift 2;;
    --region)         REGION_FLAG="$2"; shift 2;;
    --delete-project) DELETE_PROJECT=1; shift;;
    --yes|-y)         YES=1; shift;;
    -h|--help)        sed -n '2,22p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

cfg() { command -v jq >/dev/null 2>&1 && [[ -f "$CONFIG" ]] && jq -r --arg k "$1" '.[$k] // empty' "$CONFIG" 2>/dev/null || true; }

# Resolve project/region: flag > terraform output > config.json.
PROJECT="$PROJECT_FLAG"
REGION="$REGION_FLAG"
[[ -z "$PROJECT" ]] && PROJECT="$(tfout project_id 2>/dev/null || true)"
[[ -z "$REGION"  ]] && REGION="$(tfout region 2>/dev/null || true)"
[[ -z "$PROJECT" ]] && PROJECT="$(cfg project_id)"
[[ -z "$REGION"  ]] && REGION="$(cfg region)"
[[ -n "$PROJECT" ]] || die "could not resolve project (pass --project or set config.json)"
REGION="${REGION:-us-central1}"
export PROJECT REGION

# --- confirm ---------------------------------------------------------------
warn "about to DESTROY all POC resources in project: $PROJECT"
[[ "$DELETE_PROJECT" == 1 ]] && warn "MODE: delete the ENTIRE project '$PROJECT'"
if [[ "$YES" != 1 ]]; then
  read -r -p "type 'destroy' to confirm: " ans
  [[ "$ans" == "destroy" ]] || die "aborted"
fi

# --- fast path: nuke the whole project -------------------------------------
if [[ "$DELETE_PROJECT" == 1 ]]; then
  say "deleting project $PROJECT"
  gcloud projects delete "$PROJECT" --quiet
  ok "project deletion scheduled. (Terraform state is now stale; delete terraform/*.tfstate if reusing.)"
  exit 0
fi

# --- graceful teardown via terraform ---------------------------------------
say "pause scheduler (ignore if absent)"
gcloud scheduler jobs pause datalake-stream-tick --location="$REGION" --project="$PROJECT" 2>/dev/null || true

say "stop the Datastream stream (ignore if absent)"
sid="$(tfout stream_id 2>/dev/null || echo alloydb-to-iceberg)"
gcloud datastream streams update "$sid" --location="$REGION" --project="$PROJECT" \
  --state=PAUSED --update-mask=state 2>/dev/null || true

say "empty the Datastream-owned alloydb_iceberg dataset (non-Terraform tables)"
for t in $(bq --project_id="$PROJECT" ls --max_results=200 alloydb_iceberg 2>/dev/null | awk 'NR>2{print $1}'); do
  echo "   drop alloydb_iceberg.$t"
  bq --project_id="$PROJECT" rm -f -t "alloydb_iceberg.$t" || true
done

say "terraform destroy (all managed resources)"
terraform -chdir="$TF_DIR" destroy -auto-approve

# GCP auto-creates a gen2 Cloud Functions source-staging bucket that Terraform
# does not own; remove it so no GCS buckets linger.
say "remove leftover Cloud Functions staging bucket (if any)"
pnum="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null || true)"
[[ -n "$pnum" ]] && gcloud storage rm -r "gs://gcf-v2-sources-${pnum}-${REGION}" --project="$PROJECT" 2>/dev/null || true

ok "teardown complete for project $PROJECT"
echo "verify:  gcloud storage buckets list --project $PROJECT ; bq --project_id=$PROJECT ls"
echo "if anything lingered, re-run, or use:  ./destroy.sh --project $PROJECT --delete-project"
