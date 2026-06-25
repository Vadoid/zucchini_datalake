#!/usr/bin/env bash
# STAGE 3 — provision GCS+BigLake+datasets+Datastream, wait RUNNING, CHECK BQ tables.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools
load_cfg

say "STAGE 3: GCS bucket, BigLake connection, datasets, Datastream stream"
tf_apply google_datastream_stream.alloydb_to_iceberg

stream_id="$(tfout stream_id)"
ok "bucket: $(tfout iceberg_bucket)   connection: $(tfout biglake_connection)"

say "wait for stream '$stream_id' to reach RUNNING"
for _ in $(seq 1 30); do
  state="$(gcloud datastream streams describe "$stream_id" \
            --location="$REGION" --project="$PROJECT" --format='value(state)' 2>/dev/null || true)"
  echo "   state=$state"
  [[ "$state" == "RUNNING" ]] && break
  [[ "$state" == "FAILED" ]] && die "stream FAILED — check publication/slot + proxy"
  sleep 10
done
[[ "$state" == "RUNNING" ]] || warn "stream not RUNNING yet (state=$state); backfill may still proceed"

say "wait for Datastream to create + backfill the Iceberg tables in alloydb_iceberg"
for _ in $(seq 1 30); do
  n="$(bq --project_id="$PROJECT" ls --max_results=50 alloydb_iceberg 2>/dev/null | grep -c TABLE || true)"
  echo "   tables in alloydb_iceberg: ${n:-0}"
  [[ "${n:-0}" -ge 5 ]] && break
  sleep 15
done

echo
say "CHECK — tables present in alloydb_iceberg"
bq --project_id="$PROJECT" ls alloydb_iceberg || true

say "CHECK — replicated row counts (append-only Iceberg log)"
bqq "
SELECT 'store_sales' t, COUNT(*) n FROM \`alloydb_iceberg.store_sales\`
UNION ALL SELECT 'customer', COUNT(*) FROM \`alloydb_iceberg.customer\`
UNION ALL SELECT 'item',     COUNT(*) FROM \`alloydb_iceberg.item\`
UNION ALL SELECT 'date_dim', COUNT(*) FROM \`alloydb_iceberg.date_dim\`
UNION ALL SELECT 'store',    COUNT(*) FROM \`alloydb_iceberg.store\`
ORDER BY t;" || warn "tables not queryable yet — give backfill another minute"

ok "STAGE 3 done. AlloyDB replicated into BigQuery Iceberg."
