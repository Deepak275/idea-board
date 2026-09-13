# infra/stacks/gcp/main.tf
#
# GCP stack: wires the three cloud-agnostic modules together in the fixed order
# network -> cluster -> database. The module *interfaces* are IDENTICAL to the
# AWS stack (infra/stacks/aws/main.tf); only the provider and the module
# implementations differ. That is the whole cloud-agnostic thesis in one file.

provider "google" {
  project = var.project_id
  region  = var.region
}

module "network" {
  source = "../../modules/gcp/network"

  name   = var.name
  region = var.region
  cidr   = var.vpc_cidr
}

module "cluster" {
  source = "../../modules/gcp/cluster"

  name        = var.name
  region      = var.region
  k8s_version = var.k8s_version
  node_size   = var.node_size
  node_count  = var.node_count

  network = {
    network_id         = module.network.network_id
    subnet_ids         = module.network.subnet_ids
    private_subnet_ids = module.network.private_subnet_ids
  }
}

module "database" {
  source = "../../modules/gcp/database"

  name           = var.name
  engine_version = var.db_engine_version
  size           = var.db_size
  storage_gb     = var.db_storage_gb

  network = {
    network_id         = module.network.network_id
    subnet_ids         = module.network.subnet_ids
    private_subnet_ids = module.network.private_subnet_ids
  }

  allowed_cidrs = concat([var.vpc_cidr], var.db_allowed_cidrs)
}

# --- ESO Workload Identity binding (GCP-specific glue, post-cluster) --------
# Binds the in-cluster External-Secrets KSA (external-secrets/external-secrets)
# to the ESO Google SA created by the bootstrap seed. Can only exist AFTER the
# cluster does (GKE auto-creates the <project>.svc.id.goog Workload Identity
# pool on the first WI cluster), hence depends_on the cluster. Lives in the
# stack — cloud-specific glue, like the EKS access entry in the AWS stack — so
# the shared module contract stays clean. The ESO SA is named by the bootstrap.
resource "google_service_account_iam_member" "eso_wi" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/idea-board-eso@${var.project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"

  depends_on = [module.cluster]
}
