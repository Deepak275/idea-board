# infra/modules/gcp/network/outputs.tf
#
# EXACT cross-cloud network module contract (identical to modules/aws/network):
#   outputs { network_id, subnet_ids (list), private_subnet_ids (list) }
#
# GCP mapping note: GCP does not use the AWS public/private subnet dichotomy.
# GKE is VPC-native and private (egress via Cloud NAT). We therefore return the
# SAME single subnetwork self_link in both subnet_ids and private_subnet_ids so
# the module signature stays identical to AWS. The pod/service secondary ranges
# are exposed by CONVENTION as the fixed names "pods" and "services" (consumed
# by the cluster module) — see main.tf.

output "network_id" {
  description = "VPC network self_link / id."
  value       = google_compute_network.this.id
}

output "subnet_ids" {
  description = "Subnetwork self_link (single element; GCP is VPC-native)."
  value       = [google_compute_subnetwork.this.self_link]
}

output "private_subnet_ids" {
  description = "Same subnetwork self_link (GKE nodes are private via Cloud NAT)."
  value       = [google_compute_subnetwork.this.self_link]
}
