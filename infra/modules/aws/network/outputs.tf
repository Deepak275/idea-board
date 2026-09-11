# infra/modules/aws/network/outputs.tf
#
# EXACT cross-cloud network module contract:
#   outputs { network_id, subnet_ids (list), private_subnet_ids (list) }
#
# Convention for this repo: subnet_ids == the PUBLIC subnets (internet-facing,
# used for public LBs / ingress), private_subnet_ids == the PRIVATE subnets
# (worker nodes + database). The cluster module consumes both; the database
# module consumes only the private ones.

output "network_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "Public subnet IDs (internet-facing)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (worker nodes + database)."
  value       = aws_subnet.private[*].id
}
