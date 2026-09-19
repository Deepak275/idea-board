# infra/platform/versions.tf
#
# Portable platform layer — Terraform + provider version pins.
# This layer is applied IDENTICALLY on every cloud; the only cloud-conditional
# bit lives in main.tf (the ClusterSecretStore provider block, keyed off var.cloud).

terraform {
  required_version = ">= 1.5.0"

  # Remote state so the installed add-ons are tracked across pipeline runs.
  # Without this, CI state was ephemeral and every apply tried to recreate the
  # already-installed releases ("cannot re-use a name that is still in use").
  # Partial config: the pipeline passes bucket/key/region/dynamodb_table on init.
  backend "s3" {}

  required_providers {
    # Installs the platform add-ons and the idea-board app chart.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }

    # Used only for namespaces / lookups; app resources come from the Helm chart.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }

    # Applies the ClusterIssuer + ClusterSecretStore CRs. We use the kubectl
    # provider (not kubernetes_manifest) on purpose: kubectl_manifest applies at
    # APPLY time and does NOT require the CRD to exist at PLAN time. cert-manager
    # and external-secrets install their CRDs in the same apply, so a plan-time
    # CRD lookup (as kubernetes_manifest does) would fail on a fresh cluster.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
