#!/usr/bin/env bash
# STAGE 5 — build common_layer views, start continuous streaming,
#           watch the joined data change as AlloyDB -> Iceberg replicates.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools
load_cfg

ITERS="${1:-5}"     # how many observation rounds
GAP="${2:-90}"      # seconds between rounds (>= data_freshness + scheduler tick)

say "STAGE 5: create common_layer views (dedup-to-current + cross-source join)"
bq --project_id="$PROJECT" query --use_legacy_sql=false < "$SQL_DIR/05_common_layer_views.sql"
ok "views created"

say "validation queries (sql/06)"
bq --project_id="$PROJECT" query --use_legacy_sql=false < "$SQL_DIR/06_bigquery_validate.sql" || true

say "START continuous streaming (resume scheduler — fires every minute)"
gcloud scheduler jobs resume datalake-stream-tick --location="$REGION" --project="$PROJECT"

snapshot() {
  bqq "
  SELECT
    (SELECT COUNT(*) FROM \`alloydb_iceberg.public_store_sales\`)      AS appendlog_rows,
    (SELECT COUNT(*) FROM \`common_layer.store_sales_current\`) AS current_rows,
    (SELECT MAX(datastream_metadata.source_timestamp)
       FROM \`alloydb_iceberg.public_store_sales\`)                    AS latest_cdc;"
}

echo
say "WATCH — $ITERS rounds, ${GAP}s apart. store_sales should climb as data replicates."
for i in $(seq 1 "$ITERS"); do
  echo -e "${c_yel}--- round $i/$ITERS ---${c_off}"
  snapshot
  say "channel revenue by category (store=AlloyDB live, web=BigQuery Iceberg):"
  bqq "SELECT * FROM \`common_layer.channel_revenue_by_category\` ORDER BY i_category, channel;"
  [[ "$i" -lt "$ITERS" ]] && { say "sleep ${GAP}s..."; sleep "$GAP"; }
done

say "STOP streaming (pause scheduler)"
gcloud scheduler jobs pause datalake-stream-tick --location="$REGION" --project="$PROJECT"

ok "STAGE 5 done. Joined common_layer reflects live AlloyDB + static BigQuery Iceberg."
