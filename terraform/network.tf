# ---------------------------------------------------------------------------
# VPC + Private Services Access (AlloyDB private IP) + Serverless VPC connector
# ---------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  project                 = local.project_id
  name                    = var.vpc_name
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "primary" {
  project       = local.project_id
  name          = "${var.vpc_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.80.0.0/24"

  private_ip_google_access = true
}

# Allocated range that Service Networking hands to AlloyDB for its private IP.
resource "google_compute_global_address" "psa_range" {
  project       = local.project_id
  name          = var.psa_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}

# Serverless VPC Access connector — lets the Cloud Function reach the AlloyDB private IP.
resource "google_vpc_access_connector" "connector" {
  project       = local.project_id
  name          = "datalake-vpcconn"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.8.0.0/28"

  depends_on = [google_project_service.apis]
}

# Allow the reverse-proxy VM and connector range to reach AlloyDB (5432) inside the VPC.
resource "google_compute_firewall" "allow_internal" {
  project = local.project_id
  name    = "${var.vpc_name}-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["5432", "22"]
  }

  source_ranges = [
    "10.80.0.0/24", # primary subnet (proxy VM)
    "10.8.0.0/28",  # vpc connector
    var.datastream_cidr,
  ]
}

# IAP range, so you can SSH the proxy VM without a public IP for debugging.
resource "google_compute_firewall" "allow_iap_ssh" {
  project       = local.project_id
  name          = "${var.vpc_name}-allow-iap-ssh"
  network       = google_compute_network.vpc.id
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
