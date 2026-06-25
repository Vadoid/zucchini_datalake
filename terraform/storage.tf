# ---------------------------------------------------------------------------
# GCS bucket (Iceberg parquet storage) + BigLake Cloud-resource connection.
# Bucket, BQ datasets and Datastream connection share var.region.
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "iceberg" {
  project                     = local.project_id
  name                        = "${var.project_id}-iceberg-${random_id.suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels

  depends_on = [google_project_service.apis]
}

# BigLake connection used by every Iceberg table to read/write the bucket.
resource "google_bigquery_connection" "biglake" {
  project       = local.project_id
  connection_id = "biglake-iceberg"
  location      = var.region
  cloud_resource {}

  depends_on = [google_project_service.apis]
}

# The connection's delegated SA is created asynchronously; wait for it to
# propagate before binding IAM, else: "Service account ... does not exist".
resource "time_sleep" "biglake_sa_propagation" {
  depends_on      = [google_bigquery_connection.biglake]
  create_duration = "30s"
}

# The connection's auto-created service account needs storage admin on the bucket.
resource "google_storage_bucket_iam_member" "biglake_sa" {
  bucket     = google_storage_bucket.iceberg.name
  role       = "roles/storage.admin"
  member     = "serviceAccount:${google_bigquery_connection.biglake.cloud_resource[0].service_account_id}"
  depends_on = [time_sleep.biglake_sa_propagation]
}
