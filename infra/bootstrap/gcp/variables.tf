# infra/bootstrap/gcp/variables.tf

variable "project_id" {
  description = "GCP project ID to bootstrap."
  type        = string
}

variable "region" {
  description = "Default region (e.g. us-central1)."
  type        = string
  default     = "us-central1"
}

variable "github_repo" {
  description = "owner/repo allowed to federate in (must match GitHub's assertion.repository)."
  type        = string
  default     = "Deepak275/idea-board"
}
