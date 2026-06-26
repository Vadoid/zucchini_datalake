#!/usr/bin/env bash
# Build + deploy the Sync Control Panel to Cloud Run (source deploy).
# Usage: ./ui.sh deploy|url|delete
#
# Terraform owns the runtime SA + IAM (terraform/ui.tf); this script builds the
# container from ui/ and deploys it, wiring env/secret/VPC from terraform output.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cfg

SERVICE=datalake-ui

deploy() {
  local sa connector host fn_uri secret
  sa="$(tfout ui_service_account)"      || die "no ui_service_account output — run terraform apply first"
  connector="$(tfout vpc_connector)"    || die "no vpc_connector output"
  host="$(tfout alloydb_ip)"            || die "no alloydb_ip output"
  fn_uri="$(tfout function_uri)"        || die "no function_uri output"
  secret=alloydb-password
  [[ -n "$sa" && -n "$connector" && -n "$host" && -n "$fn_uri" ]] || die "missing terraform outputs — apply first"

  local image="gcr.io/$PROJECT/datalake-ui"
  say "building $SERVICE image via Cloud Build (~2-3 min)"
  # Explicit Docker build (not `run deploy --source`): the buildpack path reads a
  # Google-managed runtimes-experiment config that 403s on older gcloud SDKs.
  gcloud builds submit "$ROOT/ui" --tag "$image" --project="$PROJECT" --quiet

  say "deploying $SERVICE to Cloud Run (public)"
  gcloud run deploy "$SERVICE" \
    --image "$image" \
    --project="$PROJECT" --region="$REGION" \
    --service-account="$sa" \
    --vpc-connector="$connector" --vpc-egress=private-ranges-only \
    --allow-unauthenticated \
    --set-env-vars="^@^PROJECT=$PROJECT@REGION=$REGION@STREAM_ID=alloydb-to-iceberg@SCHEDULER_JOB=datalake-stream-tick@BQ_DATASET=alloydb_iceberg@PUBLICATION=datalake_pub@ALLOYDB_HOST=$host@ALLOYDB_DB=tpcds@ALLOYDB_USER=postgres@FUNCTION_URI=$fn_uri" \
    --set-secrets="ALLOYDB_PASSWORD=${secret}:latest" \
    --quiet

  # Public invoker. Requires the org's iam.allowedPolicyMemberDomains to permit
  # allUsers (set a project-level allowAll override). If it's still restricted,
  # the binding fails and the service stays IAM-gated (reach via run proxy).
  if gcloud run services add-iam-policy-binding "$SERVICE" \
       --project="$PROJECT" --region="$REGION" \
       --member=allUsers --role=roles/run.invoker --quiet >/dev/null 2>&1; then
    PUBLIC=1
  else
    PUBLIC=0
    local me; me="$(gcloud config get-value account 2>/dev/null)"
    [[ -n "$me" ]] && gcloud run services add-iam-policy-binding "$SERVICE" \
      --project="$PROJECT" --region="$REGION" \
      --member="user:$me" --role=roles/run.invoker --quiet >/dev/null 2>&1
  fi
  url
}

url() {
  local u
  u="$(gcloud run services describe "$SERVICE" --project="$PROJECT" --region="$REGION" \
        --format='value(status.url)' 2>/dev/null)"
  if [[ -z "$u" ]]; then warn "$SERVICE not deployed yet"; return; fi
  ok "Sync Control Panel: $u"
  if [[ "${PUBLIC:-}" == 0 ]]; then
    say "IAM-gated (org blocks public allUsers). Open locally with:"
    echo "    gcloud run services proxy $SERVICE --region $REGION --project $PROJECT"
    echo "    then browse http://localhost:8080"
  fi
}

delete() {
  gcloud run services delete "$SERVICE" --project="$PROJECT" --region="$REGION" --quiet 2>/dev/null \
    && ok "$SERVICE deleted" || warn "$SERVICE not found"
}

case "${1:-deploy}" in
  deploy) deploy;;
  url)    url;;
  delete) delete;;
  *) die "usage: ui.sh deploy|url|delete";;
esac
