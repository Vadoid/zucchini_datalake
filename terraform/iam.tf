# ---------------------------------------------------------------------------
# Service-agent IAM grants that GCP does NOT create by default in this org,
# plus the secret + service accounts for the function and scheduler.
# ---------------------------------------------------------------------------

data "google_project" "this" {
  project_id = local.project_id
  depends_on = [google_project_service.apis]
}

# Gen2 Cloud Functions build with the DEFAULT COMPUTE service account; it needs
# build + log-write roles or the Cloud Build step fails ("missing permission on
# the build service account").
resource "google_project_iam_member" "build_builder" {
  project = local.project_id
  role    = "roles/cloudbuild.builds.builder"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "build_logging" {
  project = local.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# Datastream's PSC interface must read the network attachment
# (compute.networkAttachments.get); grant the Datastream service agent.
resource "google_project_iam_member" "datastream_network_user" {
  project = local.project_id
  role    = "roles/compute.networkUser"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-datastream.iam.gserviceaccount.com"
}

resource "google_secret_manager_secret" "db_password" {
  project   = local.project_id
  secret_id = "alloydb-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.alloydb_password
}

resource "google_service_account" "fn" {
  project      = local.project_id
  account_id   = "datalake-streamer"
  display_name = "Streaming Cloud Function SA"
}

resource "google_secret_manager_secret_iam_member" "fn_secret" {
  secret_id = google_secret_manager_secret.db_password.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.fn.email}"
}

resource "google_service_account" "scheduler" {
  project      = local.project_id
  account_id   = "datalake-scheduler"
  display_name = "Cloud Scheduler invoker SA"
}
