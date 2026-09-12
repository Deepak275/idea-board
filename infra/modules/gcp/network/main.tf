# infra/modules/gcp/network/main.tf
#
# GCP implementation of the cross-cloud network contract:
#   - a custom-mode VPC
#   - one VPC-native subnetwork with two secondary ranges ("pods", "services")
#     that GKE consumes for VPC-native (alias IP) networking
#   - Cloud Router + Cloud NAT so private GKE nodes get outbound internet
#
# The secondary ranges are fixed CIDRs chosen NOT to overlap the primary
# var.cidr (stack default primary = 10.30.0.0/16). Referenced by the cluster
# module via the literal range names below (contract can't carry extra fields).

locals {
  pods_range_name     = "pods"
  services_range_name = "services"
  pods_cidr           = "10.96.0.0/14" # must not overlap var.cidr
  services_cidr       = "10.92.0.0/18" # must not overlap var.cidr or pods_cidr
}

resource "google_compute_network" "this" {
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "this" {
  name                     = "${var.name}-subnet"
  ip_cidr_range            = var.cidr
  region                   = var.region
  network                  = google_compute_network.this.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = local.pods_range_name
    ip_cidr_range = local.pods_cidr
  }

  secondary_ip_range {
    range_name    = local.services_range_name
    ip_cidr_range = local.services_cidr
  }
}

resource "google_compute_router" "this" {
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.this.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
