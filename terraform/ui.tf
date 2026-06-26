# ---------------------------------------------------------------------------
# Sync Control Panel — runtime SA + IAM for the Cloud Run UI service.
#
# The service itself is built+deployed by `deploy.sh ui` (gcloud run deploy
# --source ui/), NOT by Terraform: Cloud Run source builds are awkward to model
# in TF and the UI iterates faster outside the apply cycle. Terraform owns only
# the identity and its grants, so the service has the right permissions the
# moment it is deployed. (Build uses the default compute SA, already granted
# cloudbuild.builds.builder + logging.logWriter in iam.tf.)
# ---------------------------------------------------------------------------

resource "google_service_account" "ui" {
  project      = local.project_id
  account_id   = "datalake-ui"
  display_name = "Sync Control Panel (Cloud Run) SA"
}

# Read + edit the stream's include_objects (per-table sync on/off, new tables).
resource "google_project_iam_member" "ui_datastream" {
  project = local.project_id
  role    = "roles/datastream.admin"
  member  = "serviceAccount:${google_service_account.ui.email}"
}

# Burst now (run_job) + auto-burst on/off (resume/pause_job).
resource "google_project_iam_member" "ui_scheduler" {
  project = local.project_id
  role    = "roles/cloudscheduler.admin"
  member  = "serviceAccount:${google_service_account.ui.email}"
}

# Per-table BQ Iceberg row counts + replication lag.
resource "google_project_iam_member" "ui_bq_data" {
  project = local.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.ui.email}"
}

resource "google_project_iam_member" "ui_bq_jobs" {
  project = local.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.ui.email}"
}

# "Burst now" invokes the streamer function directly (independent of the
# scheduler), so the UI SA needs run.invoker on that function's run service.
resource "google_cloud_run_v2_service_iam_member" "ui_fn_invoker" {
  project  = local.project_id
  location = var.region
  name     = google_cloudfunctions2_function.streamer.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.ui.email}"
}

# AlloyDB password (injected as a Cloud Run secret env var at deploy time).
resource "google_secret_manager_secret_iam_member" "ui_secret" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ui.email}"
}

# Surface what `deploy.sh ui` needs to wire the service (SA, connector, host).
output "ui_service_account" {
  value = google_service_account.ui.email
}

output "vpc_connector" {
  value = google_vpc_access_connector.connector.id
}
