# infra/platform/variables.tf
#
# Inputs for the portable platform layer. Everything above the "CLOUD-CONDITIONAL"
# section is identical across clouds. The cloud-conditional inputs only feed the
# single ClusterSecretStore provider block (+ the ESO controller's IRSA/Workload
# Identity service-account annotation, which is the unavoidable sibling of that
# block — see README "Honest leaky-abstraction note").

# ---------------------------------------------------------------------------
# Cloud selector — the ONE switch that changes behaviour.
# ---------------------------------------------------------------------------
variable "cloud" {
  description = "Which cloud this cluster runs on. Selects the ClusterSecretStore provider block (aws=SecretsManager, gcp=SecretManager). This is the ONLY cloud-conditional input."
  type        = string

  validation {
    condition     = contains(["aws", "gcp"], var.cloud)
    error_message = "cloud must be either \"aws\" or \"gcp\"."
  }
}

# ---------------------------------------------------------------------------
# Cluster connection — produced by infra/stacks/<cloud> cluster module outputs.
# ---------------------------------------------------------------------------
variable "kube_host" {
  description = "Kubernetes API server URL (cluster module output: kube_host)."
  type        = string
}

variable "kube_ca_cert" {
  description = "Base64-encoded cluster CA certificate (cluster module output: kube_ca_cert)."
  type        = string
}

variable "kube_token" {
  description = "Short-lived bearer token used to authenticate to the API server (e.g. from `aws eks get-token` / `gcloud ... print-access-token`)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Add-on chart versions (pinned; override only deliberately).
# ---------------------------------------------------------------------------
variable "ingress_nginx_chart_version" {
  description = "Helm chart version for ingress-nginx."
  type        = string
  default     = "4.11.3"
}

variable "cert_manager_chart_version" {
  description = "Helm chart version for cert-manager."
  type        = string
  default     = "v1.15.3"
}

variable "external_secrets_chart_version" {
  description = "Helm chart version for external-secrets (External Secrets Operator). Pinned to a version that serves the external-secrets.io/v1beta1 API used below."
  type        = string
  default     = "0.9.20"
}

# ---------------------------------------------------------------------------
# cert-manager ClusterIssuer (Let's Encrypt / ACME).
# ---------------------------------------------------------------------------
variable "letsencrypt_email" {
  description = "Contact email registered with the ACME (Let's Encrypt) account."
  type        = string
}

variable "acme_server" {
  description = "ACME directory URL. Defaults to Let's Encrypt production; use the staging URL while testing to avoid rate limits."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

# ---------------------------------------------------------------------------
# External Secrets Operator controller identity (namespace/SA it runs as).
# Identical field names on both clouds; the *values* differ per cloud but the
# wiring does not.
# ---------------------------------------------------------------------------
variable "eso_namespace" {
  description = "Namespace the External Secrets Operator controller runs in."
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account" {
  description = "ServiceAccount name of the External Secrets Operator controller (referenced by ClusterSecretStore auth)."
  type        = string
  default     = "external-secrets"
}

# ---------------------------------------------------------------------------
# idea-board application chart overrides. When left empty, the chart's own
# values.yaml / values-<cloud>.yaml supply these. CI passes concrete image
# coordinates + the public host here.
# ---------------------------------------------------------------------------
variable "app_namespace" {
  description = "Namespace to install the idea-board release into."
  type        = string
  default     = "idea-board"
}

variable "app_release_name" {
  description = "Helm release name for the idea-board chart."
  type        = string
  default     = "idea-board"
}

variable "ingress_host" {
  description = "Public hostname for the idea-board Ingress. Empty = use the chart default."
  type        = string
  default     = ""
}

variable "backend_image_repository" {
  description = "Override for backend.image.repository (e.g. ghcr.io/OWNER/idea-board-backend). Empty = chart default."
  type        = string
  default     = ""
}

variable "backend_image_tag" {
  description = "Override for backend.image.tag. Empty = chart default."
  type        = string
  default     = ""
}

variable "frontend_image_repository" {
  description = "Override for frontend.image.repository (e.g. ghcr.io/OWNER/idea-board-frontend). Empty = chart default."
  type        = string
  default     = ""
}

variable "frontend_image_tag" {
  description = "Override for frontend.image.tag. Empty = chart default."
  type        = string
  default     = ""
}

# ===========================================================================
# CLOUD-CONDITIONAL INPUTS — consumed ONLY by the ClusterSecretStore provider
# block and the matching ESO service-account annotation.
# ===========================================================================

# ---- AWS (used when cloud == "aws") ----
variable "aws_region" {
  description = "AWS region for the SecretsManager ClusterSecretStore provider (required when cloud=aws)."
  type        = string
  default     = ""
}

variable "aws_eso_role_arn" {
  description = "IAM role ARN (IRSA) annotated onto the ESO controller ServiceAccount so it can read AWS Secrets Manager. Required when cloud=aws."
  type        = string
  default     = ""
}

# ---- GCP (used when cloud == "gcp") ----
variable "gcp_project_id" {
  description = "GCP project ID hosting Secret Manager (required when cloud=gcp)."
  type        = string
  default     = ""
}

variable "gcp_location" {
  description = "GKE cluster location (region or zone) for the Workload Identity auth block (required when cloud=gcp)."
  type        = string
  default     = ""
}

variable "gcp_cluster_name" {
  description = "GKE cluster name for the Workload Identity auth block (required when cloud=gcp)."
  type        = string
  default     = ""
}

variable "gcp_eso_service_account_email" {
  description = "Google service account email bound to the ESO KSA via Workload Identity (annotated onto the ESO ServiceAccount). Required when cloud=gcp."
  type        = string
  default     = ""
}
