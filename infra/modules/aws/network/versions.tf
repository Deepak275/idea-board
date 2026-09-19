# infra/modules/aws/network/versions.tf
#
# Provider pins for the AWS network module.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.64"
    }
  }
}
