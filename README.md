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
  Datastream (managed PSC interface via network attachment → AlloyDB private IP)
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
- **Fully managed connectivity, no proxy VM.** Datastream reaches AlloyDB through
  a managed Private Service Connect interface attached to the VPC via a
  `google_compute_network_attachment`. Google runs the producer-side VM; you run none.
- **psql access for the deploy scripts** uses an optional AlloyDB public IP locked
  to `alloydb_authorized_cidr` (e.g. your `/32`). Datastream still uses the private IP.
  Set `alloydb_authorized_cidr = ""` to disable the public IP entirely.
- GCS bucket, all BQ datasets and the Datastream connection share one region.

## Layout
```
terraform/   all infra (VPC, AlloyDB, Datastream, BQ, GCS, function, scheduler)
function/    Python Cloud Function source (mini-batch streamer)
sql/         schema, seed, CDC setup, Iceberg load, views, validation
```

## Config: one file

`config.json` is the **single source of truth** (copy from `config.example.json`).
Edit `project_id`, `region`, `zone`, optionally `alloydb_authorized_cidr` (your
`/32` for psql). Leave `alloydb_password` as the placeholder and it is
**auto-generated** on first deploy and written back into `config.json` (local,
gitignored). `deploy.sh` renders `terraform/terraform.auto.tfvars.json` from it,
so plain `terraform` works too. You never hand-edit tfvars.

## One entrypoint: deploy.sh

```bash
cp config.example.json config.json     # set project_id, region, authorized_cidr
./deploy.sh all                        # password auto-generated, full run

# create a brand-new project (config.json holds billing_account + org_id)
./deploy.sh --create-project all

# single stages / control
./deploy.sh alloydb                    # stage 1 only
./deploy.sh demo --iters 8 --gap 90
./deploy.sh stream start|stop|once|status
./deploy.sh destroy
```

Any config key can be overridden per-run by a flag (`--project`, `--region`,
`--zone`, `--password`, `--authorized-cidr`, `--create-project`,
`--billing-account`, `--org-id`/`--folder-id`) or `TF_VAR_*` env.
`--yes` skips inter-stage pauses. `--config PATH` points at a different config.

## Staged runner (under the hood)

`scripts/` drives the whole POC stage by stage, each stage **provision, check,
demonstrate**. psql runs from your laptop straight to the AlloyDB public IP
(locked to `alloydb_authorized_cidr`); only `gcloud`/`bq`/`psql`/`terraform` needed.

```bash
cp config.example.json config.json   # set project_id, region, authorized_cidr
./deploy.sh plan >/dev/null          # one-time: render tfvars from config.json
./scripts/run_all.sh            # interactive, pauses + checks between stages
# or run stages individually:
./scripts/01_alloydb.sh         # AlloyDB + net + PSC attachment, schema, CDC, seed -> count check
./scripts/02_function.sh        # deploy streamer, trigger once              -> rows grew?
./scripts/03_datastream.sh      # GCS+BigLake+stream, wait RUNNING           -> BQ tables check
./scripts/04_bq_iceberg.sh      # native Iceberg tables + one-off load       -> count check
./scripts/05_views_demo.sh 5 90 # views, stream ON, watch joins change x5    -> live demo
```

Helpers: `scripts/stream.sh start|stop|once|status` controls streaming;
`./destroy.sh` tears everything down.

## Run order (manual, code-only)

1. **Provision infra**
   ```bash
   ./deploy.sh plan >/dev/null    # render terraform.auto.tfvars.json from config.json
   cd terraform
   terraform init
   terraform apply
   ```

2. **Create DB + schema + seed + CDC** (use the AlloyDB public IP from outputs;
   requires `alloydb_authorized_cidr` set to your IP)
   ```bash
   IP=$(terraform output -raw alloydb_public_ip)
   psql "host=$IP user=postgres sslmode=require" -c "CREATE DATABASE tpcds;"
   psql "host=$IP dbname=tpcds user=postgres sslmode=require" -f ../sql/01_alloydb_schema.sql
   psql "host=$IP dbname=tpcds user=postgres sslmode=require" -f ../sql/02_alloydb_seed.sql
   # edit 03_*.sql password to match alloydb_password first
   psql "host=$IP dbname=tpcds user=postgres sslmode=require" -f ../sql/03_alloydb_cdc_setup.sql
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
