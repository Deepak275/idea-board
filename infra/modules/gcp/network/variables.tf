# infra/modules/gcp/network/variables.tf
#
# EXACT cross-cloud network module contract (identical to modules/aws/network):
#   inputs { name, region, cidr }

variable "name" {
  description = "Name prefix applied to every network resource (e.g. \"idea-board\")."
  type        = string
}

variable "region" {
  description = "Region the subnetwork lives in. Kept in the contract so the module signature is identical across clouds."
  type        = string
}

variable "cidr" {
  description = "IPv4 CIDR block for the primary subnet range (e.g. \"10.30.0.0/16\"). Must NOT overlap the pod/service secondary ranges defined in main.tf."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block, e.g. 10.30.0.0/16."
  }
}
