# zucchini_datalake, AlloyDB → Datastream → BigQuery Iceberg POC

Terraformed proof-of-concept: a streaming AlloyDB OLTP source replicated by
Datastream into BigQuery **Iceberg** tables, joined against a separately-loaded
BigQuery Iceberg dataset through a common view layer.

## Architecture

```
VPC + Private Services Access
  └─ AlloyDB (private IP, postgres, logical_decoding=on)
       tables: store_sales (fact) + customer/item/date_dim/store (dims)
       publication "datalake_pub" + slot "datalake_slot"
        │
        │  Cloud Function (datalake-streamer)  ── mini-batch INSERTs into store_sales
        │  driven by Cloud Scheduler (every 1 min; paused = stopped)
        ▼
  Datastream (private connectivity → reverse-proxy VM → AlloyDB)
   append-only CDC into BigLake-managed Iceberg
        ▼
BigQuery
  ├─ alloydb_iceberg   append-only Iceberg log (Datastream owns these tables)
  ├─ bigquery_iceberg  native Iceberg tables web_sales / web_returns (one-off load)
  └─ common_layer      views: dedup-to-current + cross-source joins
GCS bucket ── parquet storage for both Iceberg datasets
BigLake connection ── storage.admin on the bucket
```

### Key design facts
- **Datastream → Iceberg is append-only.** Replicated tables are an append log;
  `common_layer.*_current` views dedup to latest row per PK (and drop deletes).
- **AlloyDB + Datastream peering is non-transitive.** A tiny `datastream-proxy`
  VM forwards TCP 5432 from the VPC subnet (Datastream-reachable) to the AlloyDB
  private IP. Standard documented workaround.
- GCS bucket, all BQ datasets and the Datastream connection share one region.

## Layout
```
terraform/   all infra (VPC, AlloyDB, Datastream, BQ, GCS, function, scheduler)
function/    Python Cloud Function source (mini-batch streamer)
sql/         schema, seed, CDC setup, Iceberg load, views, validation
```

## One entrypoint: deploy.sh

```bash
# full run, project + password passed in (writes terraform/terraform.tfvars)
./deploy.sh --project my-poc --password 'Str0ng!' all

# create a brand-new project
./deploy.sh --project my-poc --password 'Str0ng!' \
  --create-project --billing-account XXXXXX-XXXXXX-XXXXXX --org-id 1234567890 all

# single stages / control
./deploy.sh --project my-poc alloydb       # stage 1 only
./deploy.sh --project my-poc demo --iters 8 --gap 90
./deploy.sh stream start|stop|once|status
./deploy.sh destroy
```

Config via flags or `TF_VAR_*` env (`--project`, `--region`, `--zone`,
`--password`, `--create-project`, `--billing-account`, `--org-id`/`--folder-id`).
`--yes` skips the inter-stage pauses. `--no-write-tfvars` reuses an existing
`terraform.tfvars`.

## Staged runner (under the hood)

`scripts/` drives the whole POC stage by stage, each stage **provision, check,
demonstrate**. It tunnels to AlloyDB over IAP (proxy VM forwards 5432), so it
runs from your laptop with only `gcloud`/`bq`/`psql`/`terraform` installed.

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
./scripts/run_all.sh            # interactive, pauses + checks between stages
# or run stages individually:
./scripts/01_alloydb.sh         # AlloyDB + net + proxy, schema, CDC, seed   -> count check
./scripts/02_function.sh        # deploy streamer, trigger once              -> rows grew?
./scripts/03_datastream.sh      # GCS+BigLake+stream, wait RUNNING           -> BQ tables check
./scripts/04_bq_iceberg.sh      # native Iceberg tables + one-off load       -> count check
./scripts/05_views_demo.sh 5 90 # views, stream ON, watch joins change x5    -> live demo
```

Helpers: `scripts/stream.sh start|stop|once|status` controls streaming;
`scripts/99_destroy.sh` tears everything down.

## Run order (manual, code-only)

1. **Provision infra**
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # fill project/billing/password
   terraform init
   terraform apply
   ```

2. **Create DB + schema + seed + CDC** (use the AlloyDB IP from outputs; run from
   a host with VPC access, e.g. SSH the proxy VM via IAP, or AlloyDB Studio)
   ```bash
   psql "host=<alloydb_ip> user=postgres" -c "CREATE DATABASE tpcds;"
   psql "host=<alloydb_ip> dbname=tpcds user=postgres" -f ../sql/01_alloydb_schema.sql
   psql "host=<alloydb_ip> dbname=tpcds user=postgres" -f ../sql/02_alloydb_seed.sql
   # edit 03_*.sql password to match alloydb_password first
   psql "host=<alloydb_ip> dbname=tpcds user=postgres" -f ../sql/03_alloydb_cdc_setup.sql
   ```
   The publication/slot must exist before the Datastream stream reaches RUNNING.
   If `terraform apply` created the stream before the slot existed, it will retry;
   otherwise re-apply.

3. **Load the BigQuery Iceberg dataset (one-off)**
   ```bash
   bq query --use_legacy_sql=false < ../sql/04_bigquery_iceberg_load.sql
   ```

4. **Start streaming**
   ```bash
   gcloud scheduler jobs resume datalake-stream-tick --location <region>
   # stop:  gcloud scheduler jobs pause datalake-stream-tick --location <region>
   ```

5. **Build the common layer + validate**
   ```bash
   bq query --use_legacy_sql=false < ../sql/05_common_layer_views.sql
   bq query --use_legacy_sql=false < ../sql/06_bigquery_validate.sql
   ```

## Teardown
```bash
cd terraform && terraform destroy
```
Datastream-created tables in `alloydb_iceberg` are not Terraform-managed, 
empty the dataset / delete the stream's objects if `destroy` complains.
