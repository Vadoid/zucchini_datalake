-- common_layer views: turn the append-only Datastream Iceberg log into
-- current-state tables, then join AlloyDB data with the BigQuery Iceberg data.
--
-- Run after Datastream has created the alloydb_iceberg.* tables:
--   bq query --use_legacy_sql=false < 05_common_layer_views.sql
-- Set a default project for bq so the unqualified dataset names resolve.

-- ---------------------------------------------------------------------------
-- Current-state views: keep the latest row per primary key, drop deletes.
-- Datastream append-only adds a datastream_metadata STRUCT to every table.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW `common_layer.store_sales_current` AS
SELECT * EXCEPT (datastream_metadata, _rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY ss_sale_sk
      ORDER BY datastream_metadata.source_timestamp DESC
    ) AS _rn
  FROM `alloydb_iceberg.public_store_sales`
)
WHERE _rn = 1
  AND datastream_metadata.change_type != 'DELETE';

CREATE OR REPLACE VIEW `common_layer.customer_current` AS
SELECT * EXCEPT (datastream_metadata, _rn)
FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY c_customer_sk ORDER BY datastream_metadata.source_timestamp DESC) AS _rn
  FROM `alloydb_iceberg.public_customer`
)
WHERE _rn = 1 AND datastream_metadata.change_type != 'DELETE';

CREATE OR REPLACE VIEW `common_layer.item_current` AS
SELECT * EXCEPT (datastream_metadata, _rn)
FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY i_item_sk ORDER BY datastream_metadata.source_timestamp DESC) AS _rn
  FROM `alloydb_iceberg.public_item`
)
WHERE _rn = 1 AND datastream_metadata.change_type != 'DELETE';

CREATE OR REPLACE VIEW `common_layer.date_dim_current` AS
SELECT * EXCEPT (datastream_metadata, _rn)
FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY d_date_sk ORDER BY datastream_metadata.source_timestamp DESC) AS _rn
  FROM `alloydb_iceberg.public_date_dim`
)
WHERE _rn = 1 AND datastream_metadata.change_type != 'DELETE';

CREATE OR REPLACE VIEW `common_layer.store_current` AS
SELECT * EXCEPT (datastream_metadata, _rn)
FROM (
  SELECT *, ROW_NUMBER() OVER (
    PARTITION BY s_store_sk ORDER BY datastream_metadata.source_timestamp DESC) AS _rn
  FROM `alloydb_iceberg.public_store`
)
WHERE _rn = 1 AND datastream_metadata.change_type != 'DELETE';

-- ---------------------------------------------------------------------------
-- Unified sales across channels: store (AlloyDB) + web (BigQuery Iceberg),
-- enriched with the AlloyDB item dimension.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW `common_layer.sales_unified` AS
WITH store_ch AS (
  SELECT 'store' AS channel, ss.ss_item_sk AS item_sk, ss.ss_sold_date_sk AS date_sk,
         ss.ss_quantity AS quantity, ss.ss_net_paid AS net_paid
  FROM `common_layer.store_sales_current` ss
),
web_ch AS (
  SELECT 'web' AS channel, ws.ws_item_sk AS item_sk, ws.ws_sold_date_sk AS date_sk,
         ws.ws_quantity AS quantity, ws.ws_net_paid AS net_paid
  FROM `bigquery_iceberg.web_sales` ws
),
all_sales AS (
  SELECT * FROM store_ch UNION ALL SELECT * FROM web_ch
)
SELECT
  s.channel,
  s.item_sk,
  i.i_category,
  i.i_brand,
  d.d_year,
  d.d_moy,
  s.quantity,
  s.net_paid
FROM all_sales s
LEFT JOIN `common_layer.item_current`     i ON s.item_sk = i.i_item_sk
LEFT JOIN `common_layer.date_dim_current` d ON s.date_sk = d.d_date_sk;

-- ---------------------------------------------------------------------------
-- Channel revenue comparison by category (the headline join result).
-- Web revenue is netted against web_returns (BigQuery Iceberg); store has no
-- returns source, so returns_amt is 0 for the store channel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW `common_layer.channel_revenue_by_category` AS
WITH gross AS (
  SELECT i_category, channel,
         COUNT(*)            AS line_items,
         SUM(quantity)       AS units,
         ROUND(SUM(net_paid), 2) AS gross_revenue
  FROM `common_layer.sales_unified`
  GROUP BY i_category, channel
),
web_returns_by_cat AS (
  SELECT i.i_category,
         'web' AS channel,
         SUM(wr.wr_return_quantity)      AS returns_units,
         ROUND(SUM(wr.wr_return_amt), 2) AS returns_amt
  FROM `bigquery_iceberg.web_returns` wr
  JOIN `common_layer.item_current` i ON wr.wr_item_sk = i.i_item_sk
  GROUP BY i.i_category
)
SELECT
  g.i_category,
  g.channel,
  g.line_items,
  g.units,
  g.gross_revenue,
  COALESCE(r.returns_units, 0) AS returns_units,
  COALESCE(r.returns_amt, 0)   AS returns_amt,
  ROUND(g.gross_revenue - COALESCE(r.returns_amt, 0), 2) AS net_revenue
FROM gross g
LEFT JOIN web_returns_by_cat r USING (i_category, channel)
ORDER BY g.i_category, g.channel;
