# ---------------------------------------------------------------------------
# AlloyDB minimal cluster (1 primary instance) with logical decoding for CDC.
# ---------------------------------------------------------------------------

resource "google_alloydb_cluster" "main" {
  project    = local.project_id
  cluster_id = "datalake-alloydb"
  location   = var.region

  network_config {
    network = google_compute_network.vpc.id
  }

  initial_user {
    user     = "postgres"
    password = var.alloydb_password
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = "datalake-primary"
  instance_type = "PRIMARY"

  # Smallest supported primary for a POC.
  machine_config {
    cpu_count = 2
  }

  # Datastream postgres source requires logical decoding on AlloyDB.
  database_flags = {
    "alloydb.logical_decoding" = "on"
  }

  # Public IP so the deploy scripts can run psql (schema/seed/CDC) from your
  # laptop directly. Datastream still uses the private IP via PSC. POC only —
  # locked to var.alloydb_authorized_cidr. Set enable_public_ip=false to disable.
  network_config {
    enable_public_ip = var.alloydb_authorized_cidr != ""
    dynamic "authorized_external_networks" {
      for_each = var.alloydb_authorized_cidr != "" ? [var.alloydb_authorized_cidr] : []
      content {
        cidr_range = authorized_external_networks.value
      }
    }
  }

  depends_on = [google_alloydb_cluster.main]
}
