# infra/modules/aws/cluster/variables.tf
#
# EXACT cross-cloud cluster module contract:
#   inputs { name, region, k8s_version, node_size, node_count, network }
#
# node_size is the t-shirt vocabulary shared by every cloud. Each cloud maps
# it to a real instance type internally (see main.tf).

variable "name" {
  description = "Name prefix / EKS cluster name (e.g. \"idea-board\")."
  type        = string
}

variable "region" {
  description = "Cloud region. Part of the contract signature; AWS resolves the real region from the provider."
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes control-plane version (e.g. \"1.29\")."
  type        = string
}

variable "node_size" {
  description = "T-shirt node size: one of small | medium | large."
  type        = string

  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be one of: small, medium, large."
  }
}

variable "node_count" {
  description = "Desired number of worker nodes in the managed node group."
  type        = number

  validation {
    condition     = var.node_count >= 1
    error_message = "node_count must be at least 1."
  }
}

variable "network" {
  description = "Network object emitted by the network module (network_id, subnet_ids, private_subnet_ids)."
  type = object({
    network_id         = string
    subnet_ids         = list(string)
    private_subnet_ids = list(string)
  })
}
