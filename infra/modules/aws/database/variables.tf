# infra/modules/aws/database/variables.tf
#
# EXACT cross-cloud database module contract:
#   inputs { name, engine_version, size, storage_gb, network, allowed_cidrs }

variable "name" {
  description = "Name prefix for the database resources (e.g. \"idea-board\")."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version (e.g. \"16.3\")."
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
    condition     = var.storage_gb >= 20
    error_message = "storage_gb must be at least 20 (RDS Postgres minimum for gp3)."
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

variable "allowed_cidrs" {
  description = "CIDR blocks permitted to reach Postgres on 5432 (typically the VPC / node CIDRs)."
  type        = list(string)
}
