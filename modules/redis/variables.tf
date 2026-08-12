variable "name_prefix" {
  description = "Prefix for resource names, e.g. martensa-dev."
  type        = string

  validation {
    condition     = length(var.name_prefix) <= 34
    error_message = "name_prefix must be 34 characters or fewer: an ElastiCache replication group id is capped at 40, and this module appends '-redis'."
  }
}

variable "vpc_id" {
  description = "The VPC the security group belongs to."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets. A cache with a public path is a cache anyone can read baskets out of."
  type        = list(string)
}

variable "service_security_group_id" {
  description = "The only security group allowed to reach port 6379."
  type        = string
}

variable "engine_version" {
  description = "Redis version. 7.1 matches what Cart runs against in Docker Compose and in Testcontainers."
  type        = string
  default     = "7.1"
}

variable "parameter_group_family" {
  description = "Must match the engine version's family, e.g. redis7 for any 7.x."
  type        = string
  default     = "redis7"
}

variable "node_type" {
  description = <<-EOT
    Node size. cache.t4g.micro is Graviton, 0.5 GiB, roughly $11 a month.

    0.5 GiB sounds small and is not: a basket is a few hundred bytes, so this holds hundreds of
    thousands of them. Memory is the wrong thing to size this on - connection count is, and a
    micro handles far more than a single Cart task will open.
  EOT
  type        = string
  default     = "cache.t4g.micro"
}

variable "node_count" {
  description = <<-EOT
    Nodes in the replication group. One means no failover, which is the right answer for a
    basket store - see the module header.

    Raising this to 2 enables automatic failover and Multi-AZ together, because a standby that
    cannot be promoted is only a bill.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 3
    error_message = "node_count must be between 1 and 3."
  }
}

variable "apply_immediately" {
  description = "Apply changes at once rather than in the maintenance window. Safe here - losing the cache loses only open baskets."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
