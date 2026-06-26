# POC.md, live demo runbook

A presenter's guide for driving the lakehouse demo after `./deploy.sh` completes.
Paste each query into the BigQuery console (or `bq query --use_legacy_sql=false`)
or into `psql` on AlloyDB, as marked per step.

## 1. What this demonstrates

A **cross-source lakehouse join**: live CDC from AlloyDB store sales (TPC-DS
subset) replicated by Datastream into BigQuery managed Iceberg, combined with a
**static one-off-loaded Iceberg** web-sales dataset. Both sources are unified
through `common_layer` views, append-only logs deduped to current state, then
joined. The headline result is **revenue by category per channel, net of
returns**: store revenue (AlloyDB live) next to web revenue (static Iceberg) in
a single query, while the store numbers keep climbing as the Cloud Function
streams new rows.

## 2. Architecture

```
Cloud Scheduler (datalake-stream-tick, * * * * *)
  → Cloud Function (datalake-streamer, inserts 20-60 store_sales rows)
    → AlloyDB tpcds.store_sales            (private IP via VPC connector)
      → Datastream (alloydb_to_iceberg, logical repl: datalake_pub/datalake_slot, PSC)
        → BigQuery managed Iceberg  alloydb_iceberg.public_*  (append-only + datastream_metadata)
one-off DML load → bigquery_iceberg.web_sales / web_returns (static, 5000/500 rows)
common_layer views: *_current (dedup) + sales_unified + channel_revenue_by_category
```

Three datasets, three roles:

| Dataset | Role |
|---------|------|
| `alloydb_iceberg` | Datastream-owned **append-only log**. Tables land as `public_*` (schema-prefixed), each carrying a `datastream_metadata` STRUCT. |
| `bigquery_iceberg` | User-loaded **static** web data (`web_sales`, `web_returns`). |
| `common_layer` | **Views only**: `*_current` dedup-to-latest, `sales_unified`, `channel_revenue_by_category`. |

> **Table naming.** Datastream uses `single_target_dataset` with no prefix, so
> tables land as `schema_table`: `public_store_sales`, `public_customer`,
> `public_item`, `public_store`, `public_date_dim`. Every BigQuery query below
> uses the `public_*` form.

## 3. Deploy sequence

`./deploy.sh` runs a two-phase apply (one `terraform apply` invocation per phase, with the stream gated by `var.enable_stream`):

1. **Preflight** - auth/ADC/project checks.
2. **PHASE A** - `terraform apply -var=enable_stream=false`. All infrastructure, stream gated off.
3. **DB INIT** (psql) - `sql/01_alloydb_schema`, then `sql/03_alloydb_cdc_setup` (publication `datalake_pub`, slot `datalake_slot`), then `sql/02_alloydb_seed` (365 dates, 200 customers, 100 items, 10 stores, ~2000 sales).
4. **PHASE B** - `terraform apply -var=enable_stream=true`. Creates the stream; backfill begins.
5. **LOAD** (bq) - `sql/04_bigquery_iceberg_load`: 5000 `web_sales` + 500 `web_returns`.
6. **VIEWS + DEMO** - `sql/05_common_layer_views`, then `scripts/05_views_demo.sh` (resume scheduler, watch loop, pause).

Commands:

```bash
./deploy.sh --yes                       # full provision, no prompts
./deploy.sh stream start|stop|once|status
./destroy.sh --yes                      # tear everything down
```

## 4. Step-by-step demo queries

### Step 0: (psql) Baseline source data on AlloyDB

```sql
SELECT COUNT(*) AS store_sales_rows FROM store_sales;
SELECT i_category, COUNT(*) FROM item GROUP BY i_category ORDER BY 1;
```

Shows the OLTP source seeded: ~2000 store sales across 5 item categories.

### Step 1: (bq) Datastream landed the tables (raw append-only counts)

```sql
SELECT 'store_sales' t, COUNT(*) n FROM `alloydb_iceberg.public_store_sales`
UNION ALL SELECT 'customer', COUNT(*) FROM `alloydb_iceberg.public_customer`
UNION ALL SELECT 'item',     COUNT(*) FROM `alloydb_iceberg.public_item`
UNION ALL SELECT 'date_dim', COUNT(*) FROM `alloydb_iceberg.public_date_dim`
UNION ALL SELECT 'store',    COUNT(*) FROM `alloydb_iceberg.public_store`;
```

CDC replicated all five tables into Iceberg. Counts climb over time as the
streamer fires.

### Step 2: (bq) Static web Iceberg load present

```sql
SELECT 'web_sales' t, COUNT(*) n FROM `bigquery_iceberg.web_sales`
UNION ALL SELECT 'web_returns', COUNT(*) FROM `bigquery_iceberg.web_returns`;
```

The other side of the join: 5000 web sales, 500 web returns (static).

### Step 3: (bq) Raw append-log vs deduped current

```sql
SELECT
  (SELECT COUNT(*) FROM `alloydb_iceberg.public_store_sales`)        AS raw_appendlog_rows,
  (SELECT COUNT(*) FROM `common_layer.store_sales_current`)   AS current_rows;
```

The `*_current` views collapse the append log to latest-row-per-PK. Raw ≥
current.

### Step 4: (bq) Inspect the dedup view

```sql
SELECT * FROM `common_layer.store_sales_current` LIMIT 10;
```

Clean current-state rows, `datastream_metadata` and the `_rn` helper column
stripped.

### Step 5: (bq) Unified cross-channel sales

```sql
SELECT channel, COUNT(*) line_items, ROUND(SUM(net_paid),2) revenue
FROM `common_layer.sales_unified`
GROUP BY channel ORDER BY channel;
```

Store (AlloyDB live) and web (static Iceberg) unified in one view.

### Step 6: (bq) Revenue by category per channel, net of returns

```sql
SELECT * FROM `common_layer.channel_revenue_by_category` ORDER BY i_category, channel;
```

Store vs web revenue side by side per category, with web netted against `web_returns`.

### Step 7: (bq) Freshness

```sql
SELECT MAX(datastream_metadata.source_timestamp) AS latest_cdc_event
FROM `alloydb_iceberg.public_store_sales`;
```

Recency of the last captured AlloyDB change.

### Step 8: Live CDC loop

Start streaming, then re-run the headline and watch it move:

```bash
./deploy.sh stream start      # scheduler fires Cloud Function every minute
```

Re-run **Step 1** and **Step 6** every ~90s. You'll see `store_sales` raw count and store-channel revenue climb while web stays flat. Stop with:

```bash
./deploy.sh stream stop
```

`./deploy.sh stream once` fires a single batch; `./deploy.sh stream status`
checks scheduler state.

## 5. Appendix: Reference SQL

| File | What it does |
|------|--------------|
| `sql/01_alloydb_schema.sql` | TPC-DS subset schema on AlloyDB (`store_sales`, `customer`, `item`, `store`, `date_dim`). |
| `sql/02_alloydb_seed.sql` | Seed data: 365 dates, 200 customers, 100 items, 10 stores, ~2000 store sales. |
| `sql/03_alloydb_cdc_setup.sql` | Logical replication: publication `datalake_pub`, slot `datalake_slot`. |
| `sql/04_bigquery_iceberg_load.sql` | One-off static load: 5000 `web_sales` + 500 `web_returns` into `bigquery_iceberg`. |
| `sql/05_common_layer_views.sql` | `common_layer` views: `*_current` dedup, `sales_unified`, `channel_revenue_by_category`. |
| `sql/06_bigquery_validate.sql` | Validation queries (Steps 1-7). |
