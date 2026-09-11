# infra/platform/providers.tf
#
# All three providers talk to the SAME target cluster, authenticated purely from
# passed-in variables (kube_host / kube_ca_cert / kube_token). Nothing here reads
# a local kubeconfig, and NO cloud SDK/credentials are used — the platform layer
# is cloud-agnostic. The credentials are produced upstream by the cloud stack
# (infra/stacks/<cloud>) and surfaced to CI via scripts/get-kubeconfig.sh.
#
# kube_ca_cert is base64-encoded (matches the cluster module's kube_ca_cert
# output contract), so we base64decode() it for the PEM-expecting provider args.

provider "helm" {
  kubernetes {
    host                   = var.kube_host
    cluster_ca_certificate = base64decode(var.kube_ca_cert)
    token                  = var.kube_token
  }
}

provider "kubernetes" {
  host                   = var.kube_host
  cluster_ca_certificate = base64decode(var.kube_ca_cert)
  token                  = var.kube_token
}

provider "kubectl" {
  host                   = var.kube_host
  cluster_ca_certificate = base64decode(var.kube_ca_cert)
  token                  = var.kube_token
  load_config_file       = false
}
