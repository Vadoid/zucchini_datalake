#!/usr/bin/env bash
# Orchestrator — runs all stages in order with a pause + check between each.
# Usage:  ./run_all.sh           (interactive, pauses between stages)
#         ./run_all.sh --yes     (no pauses)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools

AUTO=0
[[ "${1:-}" == "--yes" ]] && AUTO=1
gate() { [[ "$AUTO" == 1 ]] || pause; }

say "PRECHECK — config.json + rendered tfvars"
[[ -f "$CONFIG" ]] || die "create config.json (cp config.example.json config.json)"
[[ -f "$TF_DIR/terraform.auto.tfvars.json" ]] || die "render tfvars first: ./deploy.sh plan >/dev/null"

say "terraform init"
terraform -chdir="$TF_DIR" init -input=false >/dev/null
ok "init done"

D="$(dirname "${BASH_SOURCE[0]}")"
bash "$D/01_alloydb.sh";    gate
bash "$D/02_function.sh";   gate
bash "$D/03_datastream.sh"; gate
bash "$D/04_bq_iceberg.sh"; gate
bash "$D/05_views_demo.sh"

ok "ALL STAGES COMPLETE."
echo "stop streaming:  gcloud scheduler jobs pause datalake-stream-tick --location <region>"
echo "teardown:        terraform -chdir=terraform destroy"
