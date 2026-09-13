# infra/stacks/gcp/outputs.tf
#
# SAME output names as infra/stacks/aws/outputs.tf so the platform layer,
# scripts/get-kubeconfig.sh, and CI consume both clouds identically.

output "kube_host" {
  description = "Kubernetes API server endpoint."
  value       = module.cluster.kube_host
}

output "kube_ca_cert" {
  description = "Cluster CA certificate (base64)."
  value       = module.cluster.kube_ca_cert
}

output "cluster_name" {
  description = "GKE cluster name (read by scripts/get-kubeconfig.sh)."
  value       = module.cluster.cluster_name
}

output "db_host" {
  description = "Cloud SQL Postgres private IP."
  value       = module.database.db_host
}

output "region" {
  description = "GCP region (read by scripts/get-kubeconfig.sh)."
  value       = var.region
}

output "db_secret_ref" {
  description = "Secret Manager secret id for idea-board-db (credentials + DATABASE_URL)."
  value       = module.database.db_secret_ref
}

output "location" {
  description = "Cluster location (zone on GCP — zonal cluster)."
  value       = module.cluster.location
}

output "oidc_provider" {
  description = "Workload Identity pool (PROJECT_ID.svc.id.goog)."
  value       = module.cluster.oidc_provider
}

# GCP-only: needed by the platform layer's ClusterSecretStore (GCPSM provider).
output "project_id" {
  description = "GCP project ID."
  value       = var.project_id
}
