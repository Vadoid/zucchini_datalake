#!/usr/bin/env bash
# STAGE 4 — create native BigQuery Iceberg tables, one-off load, CHECK.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
check_tools
load_cfg

say "STAGE 4: bigquery_iceberg managed Iceberg tables (web_sales, web_returns)"
tf_apply \
  google_bigquery_table.web_sales \
  google_bigquery_table.web_returns

say "one-off bulk load"
bq --project_id="$PROJECT" query --use_legacy_sql=false < "$SQL_DIR/04_bigquery_iceberg_load.sql"

echo
say "CHECK — row counts in bigquery_iceberg"
bqq "
SELECT 'web_sales' t, COUNT(*) n FROM \`bigquery_iceberg.web_sales\`
UNION ALL SELECT 'web_returns', COUNT(*) FROM \`bigquery_iceberg.web_returns\`
ORDER BY t;"

say "DEMONSTRATE — sample web_sales rows"
bqq "SELECT * FROM \`bigquery_iceberg.web_sales\` LIMIT 5;"

ok "STAGE 4 done. BigQuery Iceberg tables loaded."
