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

  min_instances = 2
  max_instances = 3

  depends_on = [google_project_service.apis]
}

# Network attachment: entry point for the Datastream-managed Private Service
# Connect interface. Datastream's producer VM draws an IP from this subnet and
# reaches the AlloyDB private IP directly — no user-managed proxy.
resource "google_compute_network_attachment" "datastream" {
  provider              = google-beta
  project               = local.project_id
  name                  = "datalake-ds-na"
  region                = var.region
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.primary.self_link]

  depends_on = [google_project_service.apis]
}
