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
