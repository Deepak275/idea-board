# infra/modules/aws/cluster/versions.tf
#
# Provider pins for the AWS cluster (EKS) module.
# tls is used to derive the OIDC provider thumbprint for IRSA.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.64"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
