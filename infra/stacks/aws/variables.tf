# infra/stacks/aws/variables.tf

variable "cloud" {
  description = "Cloud selector. Present in every stack so CI can pass a uniform -var; must be \"aws\" here."
  type        = string
  default     = "aws"

  validation {
    condition     = var.cloud == "aws"
    error_message = "This stack only supports cloud = \"aws\"."
  }
}

variable "region" {
  description = "AWS region to deploy into (e.g. \"us-east-1\")."
  type        = string
}

variable "name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "idea-board"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "k8s_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.33"
}

variable "node_size" {
  description = "T-shirt worker node size: small | medium | large."
  type        = string
  default     = "small"
}

variable "node_count" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for RDS."
  type        = string
  default     = "16.3"
}

variable "db_size" {
  description = "T-shirt DB size: small | medium | large."
  type        = string
  default     = "small"
}

variable "db_storage_gb" {
  description = "Allocated RDS storage in GiB."
  type        = number
  default     = 20
}

variable "db_allowed_cidrs" {
  description = "Extra CIDRs (beyond the VPC itself) allowed to reach Postgres on 5432."
  type        = list(string)
  default     = []
}
