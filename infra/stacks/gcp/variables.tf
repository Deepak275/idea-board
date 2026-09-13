# infra/stacks/gcp/variables.tf
#
# Mirrors infra/stacks/aws/variables.tf. The ONLY extra input vs AWS is
# project_id (GCP has no provider-implicit account like AWS). Everything else —
# names, t-shirt sizes, defaults — is identical so CI passes uniform vars.

variable "cloud" {
  description = "Cloud selector. Present in every stack so CI can pass a uniform -var; must be \"gcp\" here."
  type        = string
  default     = "gcp"

  validation {
    condition     = var.cloud == "gcp"
    error_message = "This stack only supports cloud = \"gcp\"."
  }
}

variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "region" {
  description = "GCP region to deploy into (e.g. \"us-central1\")."
  type        = string
}

variable "name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "idea-board"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the primary subnet range. Must not overlap the pod/service secondary ranges (10.96.0.0/14, 10.92.0.0/18)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "k8s_version" {
  description = "GKE Kubernetes min_master_version."
  type        = string
  default     = "1.33"
}

variable "node_size" {
  description = "T-shirt worker node size: small | medium | large."
  type        = string
  default     = "small"
}

variable "node_count" {
  description = "Desired number of worker nodes (single zone, since the cluster is zonal)."
  type        = number
  # 3 e2-medium nodes. GKE reserves heavily on shared-core E2 (~945m allocatable
  # CPU per e2-medium, not ~2000m), so 2 nodes sat at ~92% from add-ons + system
  # alone and the app's replicas (2 backend + 2 frontend) couldn't schedule. 3
  # gives the headroom to run the add-ons AND the app at 2 replicas each — keeping
  # the Helm chart identical to AWS rather than trimming GCP replicas.
  default = 3
}

variable "db_engine_version" {
  description = "PostgreSQL major version for Cloud SQL."
  type        = string
  default     = "16"
}

variable "db_size" {
  description = "T-shirt DB size: small | medium | large."
  type        = string
  default     = "small"
}

variable "db_storage_gb" {
  description = "Allocated Cloud SQL storage in GiB."
  type        = number
  default     = 20
}

variable "db_allowed_cidrs" {
  description = "Extra CIDRs (informational for private-IP Cloud SQL; kept for contract parity with AWS)."
  type        = list(string)
  default     = []
}
