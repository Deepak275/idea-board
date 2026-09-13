# infra/modules/gcp/cluster/outputs.tf
#
# EXACT cross-cloud cluster module contract (identical to modules/aws/cluster):
#   outputs { cluster_name, kube_host, kube_ca_cert (base64), oidc_provider }

output "cluster_name" {
  description = "GKE cluster name (used by scripts/get-kubeconfig.sh)."
  value       = google_container_cluster.this.name
}

output "kube_host" {
  description = "Kubernetes API server endpoint URL (https://<endpoint>)."
  value       = "https://${google_container_cluster.this.endpoint}"
}

output "kube_ca_cert" {
  description = "Cluster CA certificate, base64-encoded (as GKE returns it)."
  # try() guards offline unit tests, where the mock provider returns master_auth
  # as an empty list; a real deploy always populates it (unknown at plan passes
  # through try untouched, so this never masks a real value).
  value = try(google_container_cluster.this.master_auth[0].cluster_ca_certificate, "")
}

output "oidc_provider" {
  description = "Workload Identity pool backing GKE workload identity (PROJECT_ID.svc.id.goog) — GCP analogue of the EKS IRSA OIDC provider."
  value       = "${local.project_id}.svc.id.goog"
}

output "location" {
  description = "Cluster location — the ZONE on GCP (cluster is zonal). Used by get-kubeconfig (--location) and the ESO ClusterSecretStore (clusterLocation)."
  value       = local.zone
}
