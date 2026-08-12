variable "name_prefix" {
  description = "Prefix for every resource name, e.g. martensa-dev."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits and hyphens, 3-21 characters, starting with a letter."
  }
}

variable "region" {
  description = "AWS region, used to build VPC endpoint service names."
  type        = string
}

variable "cidr_block" {
  description = "The VPC's address range. A /16, so the /24 subnets carved from it stay legible."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.cidr_block)) && tonumber(split("/", var.cidr_block)[1]) <= 16
    error_message = "cidr_block must be valid CIDR notation with a prefix of /16 or larger."
  }
}

variable "availability_zone_count" {
  description = <<-EOT
    How many availability zones to spread across.

    One is the default and it is a deliberate cost choice, not an oversight: a second AZ doubles
    the interface endpoints (billed per ENI per hour) and is only worth paying for when
    something is actually serving customers. Nothing here assumes one - the subnets, the
    endpoints and the ECS services all take a list - so raising this is a variable change and a
    plan, not a rewrite.

    What it does NOT buy on its own: RDS availability. That needs `multi_az` on the database,
    which is a separate charge and a separate decision.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.availability_zone_count >= 1 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be between 1 and 3."
  }
}

variable "gateway_port" {
  description = "The port the API gateway listens on; the load balancer is allowed to reach only this."
  type        = number
  default     = 9000
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
