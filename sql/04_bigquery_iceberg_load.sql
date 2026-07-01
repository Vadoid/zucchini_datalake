-- One-off bulk load into the native BigQuery Iceberg tables (bigquery_iceberg).
-- Keys line up with the AlloyDB dimensions (item 1..100, customer 1..200,
-- date_sk 20250101..20251231) so the common_layer joins resolve.
--
-- Run:  bq query --use_legacy_sql=false < 04_bigquery_iceberg_load.sql
-- Replace PROJECT below or set a default project for bq.

DECLARE proj STRING DEFAULT @@project_id;

-- ~5000 online sales.
INSERT INTO `bigquery_iceberg.web_sales`
  (ws_order_number, ws_item_sk, ws_sold_date, ws_bill_customer_sk,
   ws_quantity, ws_sales_price, ws_net_paid)
SELECT
  n                                                   AS ws_order_number,
  CAST(1  + FLOOR(RAND() * 100) AS INT64)             AS ws_item_sk,
  DATE_ADD(DATE '2025-01-01', INTERVAL CAST(FLOOR(RAND() * 365) AS INT64) DAY) AS ws_sold_date,
  CAST(1  + FLOOR(RAND() * 200) AS INT64)             AS ws_bill_customer_sk,
  qty,
  CAST(price AS NUMERIC)                               AS ws_sales_price,
  CAST(ROUND(qty * price, 2) AS NUMERIC)               AS ws_net_paid
FROM UNNEST(GENERATE_ARRAY(1, 5000)) AS n,
UNNEST([STRUCT(
  CAST(1 + FLOOR(RAND() * 9) AS INT64) AS qty,
  ROUND(1 + RAND() * 249, 2)           AS price
)]);

-- ~500 returns referencing a subset of order numbers.
INSERT INTO `bigquery_iceberg.web_returns`
  (wr_order_number, wr_item_sk, wr_returned_date, wr_return_quantity, wr_return_amt)
SELECT
  CAST(1 + FLOOR(RAND() * 5000) AS INT64)             AS wr_order_number,
  CAST(1 + FLOOR(RAND() * 100) AS INT64)              AS wr_item_sk,
  DATE_ADD(DATE '2025-01-01', INTERVAL CAST(FLOOR(RAND() * 365) AS INT64) DAY) AS wr_returned_date,
  CAST(1 + FLOOR(RAND() * 3) AS INT64)                AS wr_return_quantity,
  CAST(ROUND(1 + RAND() * 120, 2) AS NUMERIC)         AS wr_return_amt
FROM UNNEST(GENERATE_ARRAY(1, 500)) AS n;
