# infra/modules/gcp/cluster/main.tf
#
# GCP implementation of the cross-cloud cluster contract: a ZONAL, VPC-native
# GKE cluster with Workload Identity and a separately-managed node pool.
#
# t-shirt -> machine type map (GCP side of the shared vocabulary):
#   small=e2-medium | medium=e2-standard-4 | large=e2-standard-8

locals {
  machine_type = {
    small  = "e2-medium"
    medium = "e2-standard-4"
    large  = "e2-standard-8"
  }[var.node_size]

  # ZONAL cluster (single zone), NOT regional — deliberate cost choice. A zonal
  # GKE control plane is FREE and runs node_count nodes in ONE zone; a regional
  # control plane is billed (~$0.10/hr ≈ $73/mo) AND replicates the node pool
  # across ~3 zones (so node_count=1 becomes 3 nodes). For a cost-bounded demo
  # that fits the $300 free credit, zonal is right; a production HA setup would
  # use var.region directly (regional). Derive a zone from the region.
  zone = "${var.region}-a"

  # Fixed secondary range names created by the network module (by convention).
  pods_range_name     = "pods"
  services_range_name = "services"

  # Project ID for the Workload Identity pool. coalesce keeps the module
  # offline-unit-testable (data.google_project.project_id is null under a mock
  # provider); in a real deploy the data source resolves the project, so the
  # fallback is never used.
  project_id = coalesce(data.google_project.this.project_id, "unknown-project")
}

data "google_project" "this" {}

resource "google_container_cluster" "this" {
  name     = var.name
  location = local.zone # zonal (see locals) — free control plane, single-zone nodes

  # Manage the node pool separately (best practice) — remove the default one.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Version is managed by the REGULAR release_channel below (GKE picks a valid,
  # supported version). We deliberately do NOT pin min_master_version to the
  # cross-cloud var.k8s_version: GKE rejects a version not offered in the channel
  # (e.g. "1.33" -> "No valid versions with the prefix 1.33 found"), whereas EKS
  # accepts an exact version. So on GCP k8s_version is advisory; to pin, set a
  # channel-valid min_master_version here.

  network    = var.network.network_id
  subnetwork = var.network.subnet_ids[0]

  # VPC-native (alias IP) using the secondary ranges the network module created.
  ip_allocation_policy {
    cluster_secondary_range_name  = local.pods_range_name
    services_secondary_range_name = local.services_range_name
  }

  # Workload Identity: the GCP analogue of EKS IRSA.
  workload_identity_config {
    workload_pool = "${local.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Demo-friendly: allow terraform destroy without deletion protection.
  deletion_protection = false
}

resource "google_container_node_pool" "this" {
  name       = "${var.name}-np"
  location   = local.zone # match the cluster's zone (1 node pool in one zone)
  cluster    = google_container_cluster.this.name
  node_count = var.node_count

  node_config {
    machine_type = local.machine_type
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      project = "idea-board"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
