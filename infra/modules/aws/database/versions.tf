# infra/modules/aws/database/versions.tf
#
# Provider pins for the AWS database (RDS) module.
# random generates the master password before it is written to Secrets Manager.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.64"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
