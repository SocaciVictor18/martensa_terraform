variable "name_prefix" {
  description = "Prefix for every resource name, e.g. martensa-dev."
  type        = string
}

variable "vpc_id" {
  description = "The VPC the instance's security group belongs to."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets. A public subnet here would give the database an internet-facing endpoint."
  type        = list(string)
}

variable "service_security_group_id" {
  description = "The only security group allowed to reach port 5432."
  type        = string
}

variable "service_databases" {
  description = <<-EOT
    Database name to owning role, one entry per service that stores relational data.

    Cart is deliberately absent - it owns a Redis keyspace and no tables at all. Adding it here
    would provision a database nothing connects to, and the next person would spend an afternoon
    working out which service lost its schema.
  EOT
  type        = map(string)

  default = {
    users     = "users_svc"
    catalog   = "catalog_svc"
    inventory = "inventory_svc"
    orders    = "orders_svc"
    payments  = "payments_svc"
  }

  validation {
    condition     = alltrue([for name in keys(var.service_databases) : can(regex("^[a-z][a-z0-9_]{2,30}$", name))])
    error_message = "Database names must be lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "engine_version" {
  description = "PostgreSQL major.minor. Matches the 16 the services run against locally and in Testcontainers."
  type        = string
  default     = "16.4"
}

variable "instance_class" {
  description = <<-EOT
    Instance size. db.t4g.micro is Graviton, the cheapest class that still runs PostgreSQL 16,
    and roughly $12 a month.

    Burstable, which matters: these instances earn CPU credits while idle and spend them under
    load. A platform that is idle most of the time is exactly the shape burstable is for, but a
    sustained load will exhaust the credits and the instance throttles hard rather than slowing
    gently. If queries start timing out at a steady rate, check CPUCreditBalance before the
    query plan.
  EOT
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage in GB. 20 is the minimum gp3 allows."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "allocated_storage must be at least 20 GB."
  }
}

variable "max_allocated_storage" {
  description = <<-EOT
    Ceiling for storage autoscaling. Set above allocated_storage to enable it.

    Worth having even on a small instance: a database that fills its volume does not slow down,
    it stops accepting writes, and the service reports itself healthy the whole time because the
    health check does not write anything.
  EOT
  type        = number
  default     = 100
}

variable "multi_az" {
  description = <<-EOT
    Standby in a second availability zone. Doubles the instance cost.

    Off by default. This buys failover, not backups - a dropped table is replicated to the
    standby in milliseconds. What protects against that is backup_retention_days, which is on.
  EOT
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention. Zero disables backups entirely and also disables point-in-time recovery."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35. Zero disables point-in-time recovery and is never the right answer for a database holding orders."
  }
}

variable "skip_final_snapshot" {
  description = "Whether `terraform destroy` may drop the instance without a final snapshot. True only for a scratch environment."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuses deletion at the API level, whatever Terraform says."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Seven days of per-second metrics, free at this instance size."
  type        = bool
  default     = true
}

variable "secret_recovery_window_days" {
  description = <<-EOT
    How long Secrets Manager keeps a deleted secret before the name is reusable.

    Zero for a scratch environment so a destroy/apply cycle works. In production this must be
    7 or more: a secret deleted by mistake is otherwise unrecoverable, and the services that
    read it start failing at their next deployment rather than immediately.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (immediate) or between 7 and 30."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
