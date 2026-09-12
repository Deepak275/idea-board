# infra/modules/gcp/database/variables.tf
#
# EXACT cross-cloud database module contract (identical to modules/aws/database):
#   inputs { name, engine_version, size, storage_gb, network, allowed_cidrs }

variable "name" {
  description = "Name prefix for the database resources (e.g. \"idea-board\")."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major version (e.g. \"16\" or \"16.3\"; only the major is used to pick POSTGRES_<major>)."
  type        = string
}

variable "size" {
  description = "T-shirt instance size: one of small | medium | large."
  type        = string

  validation {
    condition     = contains(["small", "medium", "large"], var.size)
    error_message = "size must be one of: small, medium, large."
  }
}

variable "storage_gb" {
  description = "Allocated storage in GiB."
  type        = number

  validation {
    condition     = var.storage_gb >= 10
    error_message = "storage_gb must be at least 10 (Cloud SQL minimum)."
  }
}

variable "network" {
  description = "Network object emitted by the network module (network_id, subnet_ids, private_subnet_ids). Cloud SQL uses network_id for a private-IP connection."
  type = object({
    network_id         = string
    subnet_ids         = list(string)
    private_subnet_ids = list(string)
  })
}

variable "allowed_cidrs" {
  description = "Accepted for contract parity. With private-IP Cloud SQL, access is governed by the VPC peering rather than CIDR allowlists, so this is informational here."
  type        = list(string)
  default     = []
}
