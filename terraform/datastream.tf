# ---------------------------------------------------------------------------
# Datastream: AlloyDB -> BigLake Iceberg (append-only), fully managed.
# Connectivity is a Datastream-managed Private Service Connect interface that
# attaches to our VPC via a network attachment and reaches AlloyDB directly.
# ---------------------------------------------------------------------------

resource "google_datastream_private_connection" "pc" {
  project               = local.project_id
  location              = var.region
  display_name          = "datalake-pc"
  private_connection_id = "datalake-pc"

  psc_interface_config {
    network_attachment = google_compute_network_attachment.datastream.id
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.datastream_network_user,
  ]
}

# Source: PostgreSQL (AlloyDB) at its private IP, reached over the PSC interface.
resource "google_datastream_connection_profile" "src" {
  project               = local.project_id
  location              = var.region
  display_name          = "alloydb-source"
  connection_profile_id = "alloydb-source"

  postgresql_profile {
    hostname = google_alloydb_instance.primary.ip_address
    port     = 5432
    username = "datastream_user"
    password = var.alloydb_password
    database = "tpcds"
  }

  private_connectivity {
    private_connection = google_datastream_private_connection.pc.id
  }
}

# Destination: BigQuery (BigLake Iceberg). The bigquery_profile is empty;
# the Iceberg target is configured on the stream's destination_config below.
resource "google_datastream_connection_profile" "dst" {
  project               = local.project_id
  location              = var.region
  display_name          = "bq-iceberg-dest"
  connection_profile_id = "bq-iceberg-dest"

  bigquery_profile {}
}

resource "google_datastream_stream" "alloydb_to_iceberg" {
  count = var.enable_stream ? 1 : 0

  project       = local.project_id
  location      = var.region
  display_name  = "alloydb-to-iceberg"
  stream_id     = "alloydb-to-iceberg"
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.src.id

    postgresql_source_config {
      publication      = "datalake_pub"
      replication_slot = "datalake_slot"

      include_objects {
        postgresql_schemas {
          schema = "public"
          dynamic "postgresql_tables" {
            for_each = toset(["store_sales", "customer", "item", "date_dim", "store"])
            content {
              table = postgresql_tables.value
            }
          }
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.dst.id

    bigquery_destination_config {
      data_freshness = "60s"

      single_target_dataset {
        dataset_id = "${local.project_id}:${google_bigquery_dataset.alloydb_iceberg.dataset_id}"
      }

      # Write CDC into BigLake-managed Iceberg tables (parquet in our bucket).
      blmt_config {
        bucket          = google_storage_bucket.iceberg.name
        connection_name = google_bigquery_connection.biglake.name
        file_format     = "PARQUET"
        table_format    = "ICEBERG"
        root_path       = "alloydb_iceberg"
      }

      # Iceberg destination supports append-only only (no in-place merge).
      append_only {}
    }
  }

  backfill_all {}

  depends_on = [
    google_storage_bucket_iam_member.biglake_sa,
    google_bigquery_dataset.alloydb_iceberg,
  ]
}
