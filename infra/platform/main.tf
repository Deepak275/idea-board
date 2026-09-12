# infra/platform/main.tf
#
# PORTABLE PLATFORM LAYER — applied identically on every cloud.
#
# Install order (encoded via depends_on):
#   1. ingress-nginx            (LoadBalancer + IngressClass "nginx")
#   2. cert-manager (+CRDs)     -> ClusterIssuer "letsencrypt"
#   3. external-secrets (+CRDs) -> ClusterSecretStore "cloud-secrets"
#   4. idea-board app chart     (-f values.yaml -f values-<cloud>.yaml)
#
# The ONLY cloud-conditional resource is the ClusterSecretStore's provider block
# (local.cluster_secret_store_provider) plus the matching ESO ServiceAccount
# annotation. Everything else is byte-for-byte identical across clouds.

# ---------------------------------------------------------------------------
# Cross-variable input validation (terraform_data supports lifecycle
# preconditions on any TF >= 1.4). This fails fast with a clear message instead
# of producing a broken ClusterSecretStore.
# ---------------------------------------------------------------------------
resource "terraform_data" "input_guard" {
  input = var.cloud

  lifecycle {
    precondition {
      condition     = var.cloud != "aws" || (var.aws_region != "" && var.aws_eso_role_arn != "")
      error_message = "cloud=aws requires aws_region and aws_eso_role_arn to be set."
    }
    precondition {
      condition = var.cloud != "gcp" || (
        var.gcp_project_id != "" &&
        var.gcp_location != "" &&
        var.gcp_cluster_name != "" &&
        var.gcp_eso_service_account_email != ""
      )
      error_message = "cloud=gcp requires gcp_project_id, gcp_location, gcp_cluster_name and gcp_eso_service_account_email to be set."
    }
  }
}

# ---------------------------------------------------------------------------
# 1. ingress-nginx
#    Provides the cluster IngressClass "nginx" and a cloud LoadBalancer. The
#    cloud-specific LB annotations are NOT set here — they live in the app
#    chart's values-<cloud>.yaml overlay (per the shared contract).
# ---------------------------------------------------------------------------
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version

  # Default IngressClass so the chart's Ingress (ingress.className=nginx) resolves.
  set {
    name  = "controller.ingressClassResource.default"
    value = "true"
  }

  wait    = true
  timeout = 600

  depends_on = [terraform_data.input_guard]
}

# ---------------------------------------------------------------------------
# 2. cert-manager (+ CRDs) and the Let's Encrypt ClusterIssuer.
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version

  # v1.15+ manages CRDs under the crds.* keys.
  set {
    name  = "crds.enabled"
    value = "true"
  }

  wait    = true
  timeout = 600

  depends_on = [terraform_data.input_guard]
}

# HTTP-01 solver over the ingress-nginx class. Applied at APPLY time (kubectl
# provider) so it does not need the cert-manager CRD to exist at PLAN time.
resource "kubectl_manifest" "letsencrypt_cluster_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt"
    }
    spec = {
      acme = {
        server = var.acme_server
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                class = "nginx"
              }
            }
          }
        ]
      }
    }
  })

  # cert-manager's webhook must be up before a ClusterIssuer is admitted.
  depends_on = [helm_release.cert_manager]
}

# ---------------------------------------------------------------------------
# 3. External Secrets Operator (+ CRDs) and the ClusterSecretStore.
#    The ESO ServiceAccount gets a cloud-specific identity annotation so the
#    controller can reach the cloud secret store (IRSA on AWS, Workload Identity
#    on GCP). This annotation is the sibling of the cloud-conditional block below.
# ---------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = var.eso_namespace
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = var.eso_service_account
  }

  # AWS: annotate the controller SA with its IRSA role.
  dynamic "set" {
    for_each = var.cloud == "aws" ? [1] : []
    content {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = var.aws_eso_role_arn
    }
  }

  # GCP: bind the controller SA to a Google service account via Workload Identity.
  dynamic "set" {
    for_each = var.cloud == "gcp" ? [1] : []
    content {
      name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
      value = var.gcp_eso_service_account_email
    }
  }

  wait    = true
  timeout = 600

  depends_on = [terraform_data.input_guard]
}

# >>> THE ONLY CLOUD-CONDITIONAL LOGIC IN THE ENTIRE PORTABLE LAYER <<<
# Selects the ESO provider block for the ClusterSecretStore named "cloud-secrets".
# Both point at the same logical remote key "idea-board/db" (resolved by the
# chart's ExternalSecret). db_secret_ref from the database module maps to it.
#
# NOTE: the branches are compared as fully-rendered YAML *strings* (yamlencode
# returns a string). This is deliberate: a ternary over the raw AWS/GCP objects
# would fail Terraform type-unification, since the two provider blocks have
# different attribute names/shapes (aws vs gcpsm).
locals {
  cloud_secrets_store_yaml = var.cloud == "aws" ? yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "cloud-secrets" }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = var.eso_service_account
                namespace = var.eso_namespace
              }
            }
          }
        }
      }
    }
    }) : yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "cloud-secrets" }
    spec = {
      provider = {
        gcpsm = {
          projectID = var.gcp_project_id
          auth = {
            workloadIdentity = {
              clusterLocation = var.gcp_location
              clusterName     = var.gcp_cluster_name
              serviceAccountRef = {
                name      = var.eso_service_account
                namespace = var.eso_namespace
              }
            }
          }
        }
      }
    }
  })
}

resource "kubectl_manifest" "cloud_secrets_store" {
  yaml_body = local.cloud_secrets_store_yaml

  depends_on = [helm_release.external_secrets]
}

# ---------------------------------------------------------------------------
# 4. The idea-board application chart.
#    Layered values exactly like the CI contract: -f values.yaml -f values-<cloud>.yaml.
#    Optional overrides (image coords, host) are applied on top only when set,
#    so CI can inject the freshly built GHCR tags without editing chart files.
# ---------------------------------------------------------------------------
resource "helm_release" "idea_board" {
  name             = var.app_release_name
  namespace        = var.app_namespace
  create_namespace = true
  chart            = "${path.module}/../../charts/idea-board"

  values = [
    file("${path.module}/../../charts/idea-board/values.yaml"),
    file("${path.module}/../../charts/idea-board/values-${var.cloud}.yaml"),
  ]

  dynamic "set" {
    for_each = var.ingress_host != "" ? [1] : []
    content {
      name  = "ingress.host"
      value = var.ingress_host
    }
  }

  dynamic "set" {
    for_each = var.backend_image_repository != "" ? [1] : []
    content {
      name  = "backend.image.repository"
      value = var.backend_image_repository
    }
  }

  dynamic "set" {
    for_each = var.backend_image_tag != "" ? [1] : []
    content {
      name  = "backend.image.tag"
      value = var.backend_image_tag
    }
  }

  dynamic "set" {
    for_each = var.frontend_image_repository != "" ? [1] : []
    content {
      name  = "frontend.image.repository"
      value = var.frontend_image_repository
    }
  }

  dynamic "set" {
    for_each = var.frontend_image_tag != "" ? [1] : []
    content {
      name  = "frontend.image.tag"
      value = var.frontend_image_tag
    }
  }

  wait    = true
  timeout = 600

  # The app needs: the IngressClass + issuer for TLS, and the ClusterSecretStore
  # so its ExternalSecret ("idea-board-db") can materialise the DATABASE_URL Secret.
  depends_on = [
    helm_release.ingress_nginx,
    kubectl_manifest.letsencrypt_cluster_issuer,
    kubectl_manifest.cloud_secrets_store,
  ]
}
