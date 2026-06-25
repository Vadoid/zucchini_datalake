# ---------------------------------------------------------------------------
# Datastream reverse-proxy VM.
#
# Why this exists: AlloyDB's private IP lives in the Service Networking peered
# range. Datastream's private connectivity creates its OWN VPC peering. VPC
# peering is non-transitive, so Datastream cannot reach the AlloyDB IP directly.
# A tiny VM that sits IN the VPC subnet (reachable by Datastream) and forwards
# TCP 5432 to the AlloyDB IP (reachable by the VM) bridges the two peerings.
# This is Google's documented AlloyDB + Datastream workaround.
# ---------------------------------------------------------------------------

resource "google_compute_instance" "ds_proxy" {
  project      = local.project_id
  name         = "datastream-proxy"
  machine_type = "e2-small"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.primary.id
    # No public IP. Egress for apt via Cloud NAT (see below); SSH via IAP.
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y socat
    cat >/etc/systemd/system/ds-proxy.service <<'UNIT'
    [Unit]
    Description=Datastream->AlloyDB TCP proxy
    After=network-online.target
    [Service]
    ExecStart=/usr/bin/socat TCP-LISTEN:5432,fork,reuseaddr TCP:${google_alloydb_instance.primary.ip_address}:5432
    Restart=always
    [Install]
    WantedBy=multi-user.target
    UNIT
    systemctl daemon-reload
    systemctl enable --now ds-proxy
  EOT

  labels = var.labels

  depends_on = [google_alloydb_instance.primary]
}

# Cloud NAT so the no-public-IP proxy VM can apt-get install socat.
resource "google_compute_router" "nat_router" {
  project = local.project_id
  name    = "datalake-nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  project                            = local.project_id
  name                               = "datalake-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
