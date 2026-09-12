# infra/modules/aws/network/variables.tf
#
# EXACT cross-cloud network module contract:
#   inputs { name, region, cidr }

variable "name" {
  description = "Name prefix applied to every network resource (e.g. \"idea-board\")."
  type        = string
}

variable "region" {
  description = "Cloud region the VPC/subnets live in. Kept in the contract so the module signature is identical across clouds; AWS reads the actual region from the provider."
  type        = string
}

variable "cidr" {
  description = "IPv4 CIDR block for the VPC (e.g. \"10.20.0.0/16\"). Must be large enough to carve public + private /24s per AZ."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block, e.g. 10.20.0.0/16."
  }
}
