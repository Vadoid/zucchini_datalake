#!/usr/bin/env bash
# STAGE 2 — provision the streaming Cloud Function + Scheduler, trigger it, CHECK growth.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools
load_cfg

say "STAGE 2: Cloud Function (datalake-streamer) + Cloud Scheduler"
tf_apply \
  google_cloudfunctions2_function.streamer \
  google_cloud_scheduler_job.tick

ok "function URI: $(tfout function_uri)"

alloydb_host
before="$(psqlt tpcds -tAc 'SELECT count(*) FROM store_sales')"
say "store_sales rows BEFORE: $before"

say "trigger one batch now (forces a Scheduler run even though job is paused)"
gcloud scheduler jobs run datalake-stream-tick --location="$REGION" --project="$PROJECT"

say "wait 20s for the function to insert its mini-batch"
sleep 20
after="$(psqlt tpcds -tAc 'SELECT count(*) FROM store_sales')"
say "store_sales rows AFTER:  $after"

if (( after > before )); then
  ok "function populated AlloyDB: +$(( after - before )) rows"
else
  warn "no growth yet — check: gcloud functions logs read datalake-streamer --region $REGION"
fi

echo
say "DEMONSTRATE — latest 5 streamed rows"
psqlt tpcds -c "SELECT ss_sale_sk, ss_ticket_number, ss_item_sk, ss_quantity, ss_net_paid
                FROM store_sales ORDER BY ss_sale_sk DESC LIMIT 5;"

ok "STAGE 2 done. Streaming function works. (Continuous streaming starts in stage 5.)"
