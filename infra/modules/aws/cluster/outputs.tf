# infra/modules/aws/cluster/outputs.tf
#
# EXACT cross-cloud cluster module contract:
#   outputs { cluster_name, kube_host, kube_ca_cert (base64), oidc_provider }

output "cluster_name" {
  description = "EKS cluster name (used by scripts/get-kubeconfig.sh)."
  value       = aws_eks_cluster.this.name
}

output "kube_host" {
  description = "Kubernetes API server endpoint URL."
  value       = aws_eks_cluster.this.endpoint
}

output "kube_ca_cert" {
  description = "Cluster CA certificate, base64-encoded (as EKS returns it)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider" {
  description = "ARN of the IAM OIDC provider backing IRSA."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "location" {
  description = "Cluster location — the region on AWS (get-kubeconfig uses --region)."
  value       = var.region
}
