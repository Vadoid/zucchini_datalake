# ---------------------------------------------------------------------------
# Three datasets + the one-off Iceberg tables in bigquery_iceberg.
#
#   alloydb_iceberg  : Datastream auto-creates append-only Iceberg tables here.
#                      (Only the dataset is declared; tables are owned by the stream.)
#   bigquery_iceberg : managed Iceberg tables we create + bulk-load once.
#   common_layer     : views joining both (created by sql/common_layer_views.sql).
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "alloydb_iceberg" {
  project       = local.project_id
  delete_contents_on_destroy = true
  dataset_id    = "alloydb_iceberg"
  location      = var.region
  friendly_name = "AlloyDB CDC (Iceberg, append-only via Datastream)"
  labels        = var.labels

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_dataset" "bigquery_iceberg" {
  project       = local.project_id
  delete_contents_on_destroy = true
  dataset_id    = "bigquery_iceberg"
  location      = var.region
  friendly_name = "Native BigQuery Iceberg tables (one-off load)"
  labels        = var.labels

  depends_on = [google_project_service.apis]
}

resource "google_bigquery_dataset" "common_layer" {
  project       = local.project_id
  delete_contents_on_destroy = true
  dataset_id    = "common_layer"
  location      = var.region
  friendly_name = "Common layer views joining AlloyDB + BigQuery Iceberg"
  labels        = var.labels

  depends_on = [google_project_service.apis]
}

locals {
  iceberg_base_uri = "gs://${google_storage_bucket.iceberg.name}/bigquery_iceberg"
}

# --- bigquery_iceberg.web_sales (the "big" one-off fact) -------------------
resource "google_bigquery_table" "web_sales" {
  project             = local.project_id
  dataset_id          = google_bigquery_dataset.bigquery_iceberg.dataset_id
  table_id            = "web_sales"
  deletion_protection = false

  biglake_configuration {
    connection_id = google_bigquery_connection.biglake.id
    storage_uri   = "${local.iceberg_base_uri}/web_sales/"
    file_format   = "PARQUET"
    table_format  = "ICEBERG"
  }

  schema = jsonencode([
    { name = "ws_order_number", type = "INTEGER", mode = "REQUIRED" },
    { name = "ws_item_sk", type = "INTEGER", mode = "REQUIRED" },
    { name = "ws_sold_date_sk", type = "INTEGER", mode = "NULLABLE" },
    { name = "ws_bill_customer_sk", type = "INTEGER", mode = "NULLABLE" },
    { name = "ws_quantity", type = "INTEGER", mode = "NULLABLE" },
    { name = "ws_sales_price", type = "NUMERIC", mode = "NULLABLE" },
    { name = "ws_net_paid", type = "NUMERIC", mode = "NULLABLE" },
  ])

  depends_on = [google_storage_bucket_iam_member.biglake_sa]
}

# --- bigquery_iceberg.web_returns ------------------------------------------
resource "google_bigquery_table" "web_returns" {
  project             = local.project_id
  dataset_id          = google_bigquery_dataset.bigquery_iceberg.dataset_id
  table_id            = "web_returns"
  deletion_protection = false

  biglake_configuration {
    connection_id = google_bigquery_connection.biglake.id
    storage_uri   = "${local.iceberg_base_uri}/web_returns/"
    file_format   = "PARQUET"
    table_format  = "ICEBERG"
  }

  schema = jsonencode([
    { name = "wr_order_number", type = "INTEGER", mode = "REQUIRED" },
    { name = "wr_item_sk", type = "INTEGER", mode = "REQUIRED" },
    { name = "wr_returned_date_sk", type = "INTEGER", mode = "NULLABLE" },
    { name = "wr_return_quantity", type = "INTEGER", mode = "NULLABLE" },
    { name = "wr_return_amt", type = "NUMERIC", mode = "NULLABLE" },
  ])

  depends_on = [google_storage_bucket_iam_member.biglake_sa]
}
