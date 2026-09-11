# infra/stacks/aws/outputs.tf
#
# Contract outputs: kube_host, kube_ca_cert, cluster_name, db_host, region.
# (db_secret_ref and oidc_provider are exposed too — handy for the platform
# layer and IRSA wiring — but are not part of the required set.)

output "kube_host" {
  description = "Kubernetes API server endpoint."
  value       = module.cluster.kube_host
}

output "kube_ca_cert" {
  description = "Cluster CA certificate (base64)."
  value       = module.cluster.kube_ca_cert
}

output "cluster_name" {
  description = "EKS cluster name (read by scripts/get-kubeconfig.sh)."
  value       = module.cluster.cluster_name
}

output "db_host" {
  description = "RDS Postgres hostname."
  value       = module.database.db_host
}

output "region" {
  description = "AWS region (read by scripts/get-kubeconfig.sh)."
  value       = var.region
}

output "db_secret_ref" {
  description = "Secrets Manager ARN for idea-board/db (credentials + DATABASE_URL)."
  value       = module.database.db_secret_ref
}

output "oidc_provider" {
  description = "IAM OIDC provider ARN backing IRSA."
  value       = module.cluster.oidc_provider
}
