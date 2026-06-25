# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

POC: AlloyDB (TPC-DS subset) replicated by Datastream into BigQuery managed Iceberg, joined with a one-off-loaded Iceberg dataset through `common_layer` views. All infra is Terraform; one script drives everything.

## Working style

Run autonomously. Execute all CLI yourself (`gcloud`, `terraform`, `bq`, `psql`, `git`, `./deploy.sh`, `./destroy.sh`) via the shell, use background runs for long ones. Do not ask the user to run commands. Commit as work lands. Never add a `Co-Authored-By: Claude` trailer.

## Commands

```bash
./deploy.sh            # full provision + DB init + Datastream + load + demo (interactive)
./deploy.sh --yes      # same, no prompts (full auto)
./deploy.sh plan       # render tfvars from config.json + terraform plan
./deploy.sh doctor     # check required tools
./deploy.sh stream start|stop|once|status
./destroy.sh --yes     # tear everything down
```

`config.json` is the single source of truth (copy from `config.example.json`; only `project_id` is required). `deploy.sh` renders `terraform/terraform.auto.tfvars.json` from it and auto-generates `alloydb_password`. Required tools: terraform, gcloud, bq, psql, jq.

## Architecture (the non-obvious parts)

- **Two-phase apply.** One `terraform apply`, but the Datastream stream is gated behind `var.enable_stream`. `deploy.sh` applies with it off (PHASE A), runs schema + CDC publication/slot + seed over psql (DB INIT), then applies with it on (PHASE B) so the publication exists before the stream starts.
- **Fully managed connectivity, no proxy VM.** Datastream reaches AlloyDB via a PSC interface + `google_compute_network_attachment`. AlloyDB has a public IP (allow-list `alloydb_authorized_cidr`, default `0.0.0.0/0`) only so `deploy.sh` can psql in.
- **Datastream → Iceberg is append-only.** `alloydb_iceberg.*` tables are an append log; `common_layer.*_current` views dedup to latest row per PK. `channel_revenue_by_category` is the headline join (store sales from AlloyDB vs web sales from `bigquery_iceberg`, net of `web_returns`).
- **Org gives no default IAM.** This org (altostrat) requires explicit grants in `iam.tf`: compute default SA needs `cloudbuild.builds.builder` + `logging.logWriter` (gen2 build), Datastream service agent needs `compute.networkUser` (PSC attachment). Sensitive APIs enforce reauth, keep ADC fresh (`gcloud auth application-default login`); `deploy.sh` preflight checks this.

## Layout

```
deploy.sh / destroy.sh   orchestration (config.json -> tfvars -> apply -> SQL -> demo)
terraform/               all infra
function/                gen2 Cloud Function (mini-batch streamer)
sql/                     schema, seed, CDC, Iceberg load, views, validation
scripts/                 lib.sh helpers, 05_views_demo.sh, stream.sh
```

## Recovering from partial applies

Failed GCP resources (FAILED function, ERROR connector) leave orphans that 409 on re-apply. Delete the orphan with `gcloud`, then re-run `./deploy.sh`. Terraform state is local under `terraform/`.
