-- Validation queries. Run with: bq query --use_legacy_sql=false < 06_bigquery_validate.sql
-- (run statements individually as needed).

-- 1) Datastream landed the AlloyDB tables (raw append-only counts).
SELECT 'store_sales' t, COUNT(*) n FROM `alloydb_iceberg.store_sales`
UNION ALL SELECT 'customer', COUNT(*) FROM `alloydb_iceberg.customer`
UNION ALL SELECT 'item',     COUNT(*) FROM `alloydb_iceberg.item`
UNION ALL SELECT 'date_dim', COUNT(*) FROM `alloydb_iceberg.date_dim`
UNION ALL SELECT 'store',    COUNT(*) FROM `alloydb_iceberg.store`;

-- 2) Current-state row counts (after dedup) vs raw append-log counts.
--    store_sales should keep growing while the Cloud Function streams.
SELECT
  (SELECT COUNT(*) FROM `alloydb_iceberg.store_sales`)        AS raw_appendlog_rows,
  (SELECT COUNT(*) FROM `common_layer.store_sales_current`)   AS current_rows;

-- 3) BigQuery Iceberg one-off load present.
SELECT 'web_sales' t, COUNT(*) n FROM `bigquery_iceberg.web_sales`
UNION ALL SELECT 'web_returns', COUNT(*) FROM `bigquery_iceberg.web_returns`;

-- 4) The cross-source join result: store vs web revenue per category.
SELECT * FROM `common_layer.channel_revenue_by_category`;

-- 5) Freshness check: latest source_timestamp seen from AlloyDB.
SELECT MAX(datastream_metadata.source_timestamp) AS latest_cdc_event
FROM `alloydb_iceberg.store_sales`;
