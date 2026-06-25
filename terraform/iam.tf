# ---------------------------------------------------------------------------
# Secret + service accounts for the streaming Cloud Function and Scheduler.
# ---------------------------------------------------------------------------

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
