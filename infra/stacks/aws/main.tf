# infra/stacks/aws/main.tf
#
# AWS stack: wires the three cloud-agnostic modules together in the fixed order
# network -> cluster -> database. The module *interfaces* are identical to the
# GCP stack; only the provider and the module implementations differ.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "idea-board"
      ManagedBy = "terraform"
      Stack     = "aws"
    }
  }
}

module "network" {
  source = "../../modules/aws/network"

  name   = var.name
  region = var.region
  cidr   = var.vpc_cidr
}

module "cluster" {
  source = "../../modules/aws/cluster"

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
  source = "../../modules/aws/database"

  name           = var.name
  engine_version = var.db_engine_version
  size           = var.db_size
  storage_gb     = var.db_storage_gb

  network = {
    network_id         = module.network.network_id
    subnet_ids         = module.network.subnet_ids
    private_subnet_ids = module.network.private_subnet_ids
  }

  # The whole VPC (nodes live here) may reach Postgres, plus any extras.
  allowed_cidrs = concat([var.vpc_cidr], var.db_allowed_cidrs)
}
