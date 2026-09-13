# infra/bootstrap/gcp/versions.tf
#
# BOOTSTRAP SEED (run once, locally). Local state on purpose — this creates the
# identity the CI pipeline later assumes (deploy SA + Workload Identity
# Federation), so it cannot itself run in CI (chicken-and-egg). Everything
# downstream (VPC/GKE/CloudSQL/add-ons) is managed by the normal pipeline.
#
# The GCS state bucket for the main stacks is created out-of-band (a bucket that
# holds Terraform state can't be created by the Terraform that stores state in
# it) and is intentionally NOT managed here.
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
