# zucchini_datalake

Terraformed GCP proof-of-concept: a streaming **AlloyDB** OLTP source replicated by
**Datastream** into **BigQuery managed Iceberg**, joined against a separately-loaded
Iceberg dataset through a common view layer. One script drives the whole lifecycle.

## Architecture

```mermaid
flowchart LR
  SCH[Cloud Scheduler<br/>every 1 min] -->|trigger| CF[Cloud Function<br/>datalake-streamer]
  CF -->|mini-batch INSERT| ADB[(AlloyDB<br/>TPC-DS subset<br/>private IP)]

  ADB -->|Datastream CDC<br/>managed PSC interface<br/>append-only, freshness 0| ALI[(alloydb_iceberg<br/>BigLake Iceberg<br/>public_* tables)]
  LOAD[one-off DML load] --> BQI[(bigquery_iceberg<br/>web_sales / web_returns<br/>BigLake Iceberg)]

  ALI --> CL[common_layer<br/>views: dedup-to-current<br/>+ cross-source join]
  BQI --> CL
  CL --> OUT[channel_revenue_by_category<br/>store vs web, net of returns]

  GCS[(GCS bucket<br/>Parquet storage)]
  ALI -.->|/alloydb_iceberg| GCS
  BQI -.->|/bigquery_iceberg| GCS

  subgraph laptop [your laptop]
    DEP[deploy.sh] -->|psql over public IP<br/>schema/seed/CDC| ADB
    DEP -->|terraform / bq| ALL((GCP))
  end
```

Key design points:

- **Datastream → Iceberg is append-only.** The `alloydb_iceberg.public_*` tables are an
  append log (every change is a row + a `datastream_metadata` STRUCT). The
  `common_layer.*_current` views dedup to the latest row per primary key.
- **Fully managed connectivity, no proxy VM.** Datastream reaches AlloyDB through a
  managed Private Service Connect interface backed by a `network_attachment`.
- **Public IP is laptop-only.** AlloyDB has a public IP (allow-list `0.0.0.0/0` by
  default) purely so `deploy.sh` can run the schema/seed/CDC SQL via `psql`. Datastream
  itself uses the private IP. Tighten `alloydb_authorized_cidr` (or set it `""` to drop
  the public IP) for anything beyond a POC.
- **Two-phase apply.** One Terraform config, but the Datastream stream is gated behind
  `enable_stream` so the CDC publication/slot exist before the stream turns on.

## Prerequisites

- **Tools**: `terraform`, `gcloud`, `bq`, `psql`, `jq`.
  - Check missing tools using `./deploy.sh doctor`.
  - Auto-install missing packages using `./deploy.sh --install-deps`.
  - **`jq` Note**: `deploy.sh` uses `jq` to manage configuration variables. If `jq` is missing, the script will temporarily fall back to using `python3` to parse `config.json` while running checks or auto-installing `jq`.
  - **`terraform` Note**: Because `terraform` is not available in default package manager repositories, the auto-installer can fail to locate it. You can install it:
    - **Locally (Recommended)**: Download and unzip it into `~/.local/bin` (which is typically in your `$PATH`):
      ```bash
      mkdir -p ~/.local/bin
      curl -fsSL https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip -o terraform.zip
      unzip -o terraform.zip -d ~/.local/bin && rm terraform.zip
      ```
    - **System-wide via APT**: Add the HashiCorp APT repository and install:
      ```bash
      sudo apt-get update && sudo apt-get install -y gnupg software-properties-common wget
      wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com \$(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt-get update && sudo apt-get install -y terraform
      ```
- **Auth**: `gcloud auth login` **and** `gcloud auth application-default login` (Terraform uses Application Default Credentials). `deploy.sh` preflight verifies both and checks the project.
- **A GCP project**: Existing, or configure `create_project: true` along with billing/org information in `config.json`.

## Configure

`config.json` is the **single source of truth** (copy from `config.example.json`):

```json
{
  "project_id": "your-project",
  "region": "us-central1",
  "zone": "us-central1-a",
  "alloydb_password": "CHANGE-ME-strong-password",
  "alloydb_authorized_cidr": "0.0.0.0/0",
  "create_project": false,
  "demo_iters": 5,
  "demo_gap": 90
}
```

Only `project_id` is required. Leave the password as the placeholder and it is
auto-generated and written back. `deploy.sh` renders `terraform.auto.tfvars.json` from
this, so plain `terraform` works too. Any key can be overridden per-run with a flag
(`--project`, `--region`, `--password`, …) or `TF_VAR_*`.

## Deploy

```bash
./deploy.sh                 # full run, interactive (banner confirm + demo prompt)
./deploy.sh --yes           # full run, no prompts (CI / autonomous)
```

`deploy.sh all` does, in order:

| Phase | Action |
|-------|--------|
| preflight | check tools, gcloud auth, ADC, project |
| PHASE A   | `terraform apply`, all infra, Datastream stream off |
| DB INIT   | create db + schema + CDC publication/slot + seed (psql) |
| PHASE B   | `terraform apply -var=enable_stream=true`, turn the stream on |
| backfill  | wait for stream RUNNING + Iceberg tables to populate |
| load      | one-off DML into `bigquery_iceberg` |
| views+demo| build `common_layer` views, run the live streaming demo |

Other commands:

```bash
./deploy.sh plan            # render tfvars from config + terraform plan
./deploy.sh output          # terraform outputs
./deploy.sh doctor          # tool check
./deploy.sh --install-deps all   # auto-install missing tools, then deploy
```

Terraform's verbose output streams to `tf-apply-*.log`; the terminal shows compact
progress. The whole run is logged to `deploy-<timestamp>.log`.

## Monitor

```bash
# streaming control (the Cloud Scheduler job that drives the function)
./deploy.sh stream status          # ENABLED/PAUSED + schedule
./deploy.sh stream start           # begin streaming (every 1 min)
./deploy.sh stream once            # fire a single mini-batch now
./deploy.sh stream stop            # pause streaming

# Datastream health
gcloud datastream streams describe alloydb-to-iceberg \
  --location <region> --format='value(state)'      # expect RUNNING

# data validation (counts, current-state, the cross-source join)
bq query --use_legacy_sql=false < sql/06_bigquery_validate.sql

# quick row counts
bq query --use_legacy_sql=false \
  'SELECT (SELECT COUNT(*) FROM `alloydb_iceberg.public_store_sales`) AS replicated,
          (SELECT COUNT(*) FROM `common_layer.store_sales_current`)   AS current_state'

# function logs
gcloud functions logs read datalake-streamer --region <region>
```

The headline result is `common_layer.channel_revenue_by_category`: store revenue
(AlloyDB → Iceberg) vs web revenue (native Iceberg) per category, net of returns. With
streaming on, `replicated`/`current_state` climb in near-real-time (`data_freshness=0`).

## Teardown

```bash
./destroy.sh                # confirm prompt
./destroy.sh --yes          # no prompt
./destroy.sh --delete-project   # nuke the whole project (only if deploy created it)
```

`destroy.sh` pauses the scheduler, stops the stream, deletes the Datastream-created
tables in `alloydb_iceberg` (not Terraform-managed), then `terraform destroy`. GCS
buckets are `force_destroy`, so the Iceberg Parquet data is removed with them.

## Layout

```
deploy.sh / destroy.sh   lifecycle entrypoints (config.json -> tfvars -> apply -> SQL -> demo)
config.json              single source of truth (gitignored; copy from config.example.json)
terraform/               all infra (AlloyDB, VPC+PSC, Datastream, BigQuery, GCS, function, scheduler)
function/                gen2 Cloud Function, mini-batch streamer (psycopg2)
sql/                     schema, seed, CDC, Iceberg load, common_layer views, validation
scripts/                 lib.sh helpers, 05_views_demo.sh, stream.sh
```

## Notes / gotchas baked in

- Datastream names BLMT tables `<schema>_<table>` (e.g. `public_store_sales`).
- BLMT stream config requires `data_freshness = 0`, a `root_path` starting with `/`,
  and `connection_name` in `{project}.{location}.{name}` form.
- AlloyDB's `postgres` user can't create a replication slot (not a REPLICATION role);
  the slot is created as `datastream_user`.
- This org grants no default service-agent IAM: the compute default SA needs
  `cloudbuild.builds.builder` + `logging.logWriter` (gen2 build) and the Datastream
  service agent needs `compute.networkUser` (PSC attachment). All in `terraform/iam.tf`.
