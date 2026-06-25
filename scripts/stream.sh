#!/usr/bin/env bash
# Control the streaming Cloud Function via its Scheduler job.
# Usage: ./stream.sh start|stop|once|status
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_cfg
JOB=datalake-stream-tick

case "${1:-status}" in
  start)  gcloud scheduler jobs resume "$JOB" --location="$REGION" --project="$PROJECT"; ok "streaming ON (every 1 min)";;
  stop)   gcloud scheduler jobs pause  "$JOB" --location="$REGION" --project="$PROJECT"; ok "streaming OFF";;
  once)   gcloud scheduler jobs run    "$JOB" --location="$REGION" --project="$PROJECT"; ok "single batch triggered";;
  status) gcloud scheduler jobs describe "$JOB" --location="$REGION" --project="$PROJECT" --format='value(state,schedule)';;
  *) die "usage: stream.sh start|stop|once|status";;
esac
