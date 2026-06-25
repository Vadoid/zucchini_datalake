# ---------------------------------------------------------------------------
# Gen2 Cloud Function: inserts a mini-batch of store_sales rows into AlloyDB.
# Cloud Scheduler invokes it every minute. "Stop" = pause the scheduler job.
# ---------------------------------------------------------------------------

# Bucket to hold the zipped function source.
resource "google_storage_bucket" "fn_source" {
  project                     = local.project_id
  name                        = "${var.project_id}-fn-src-${random_id.suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.apis]
}

data "archive_file" "fn_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/build/function.zip"
}

resource "google_storage_bucket_object" "fn_zip" {
  name   = "function-${data.archive_file.fn_zip.output_md5}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.fn_zip.output_path
}

resource "google_cloudfunctions2_function" "streamer" {
  project  = local.project_id
  name     = "datalake-streamer"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "stream_batch"
    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.fn_zip.name
      }
    }
  }

  service_config {
    available_memory      = "256Mi"
    timeout_seconds       = 120
    max_instance_count    = 1
    service_account_email = google_service_account.fn.email

    # Reach the AlloyDB private IP through the serverless VPC connector.
    vpc_connector                 = google_vpc_access_connector.connector.id
    vpc_connector_egress_settings = "PRIVATE_RANGES_ONLY"

    environment_variables = {
      ALLOYDB_HOST = google_alloydb_instance.primary.ip_address
      ALLOYDB_DB   = "tpcds"
      ALLOYDB_USER = "postgres"
      BATCH_MIN    = "20"
      BATCH_MAX    = "60"
    }

    secret_environment_variables {
      key        = "ALLOYDB_PASSWORD"
      project_id = local.project_id
      secret     = google_secret_manager_secret.db_password.secret_id
      version    = "latest"
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.db_password,
    time_sleep.build_sa_propagation,
  ]
}

# Only the scheduler SA may invoke the function.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = local.project_id
  location = var.region
  name     = google_cloudfunctions2_function.streamer.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "tick" {
  project   = local.project_id
  region    = var.region
  name      = "datalake-stream-tick"
  schedule  = "* * * * *" # every minute; mini-batches arrive ~1-2 min apart
  time_zone = "Etc/UTC"

  # Created paused. Start streaming:  gcloud scheduler jobs resume datalake-stream-tick
  # Stop streaming:                   gcloud scheduler jobs pause  datalake-stream-tick
  paused = true

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.streamer.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloudfunctions2_function.streamer.service_config[0].uri
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.invoker]
}
