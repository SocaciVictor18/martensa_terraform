variable "name_prefix" {
  description = "Environment prefix, e.g. martensa-dev."
  type        = string
}

variable "service_name" {
  description = "Short name: users, catalog, inventory, cart, orders, payments, gateway. Becomes the internal DNS name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.service_name))
    error_message = "service_name must be lowercase letters, digits and hyphens - it becomes a DNS label."
  }
}

variable "region" {
  description = "AWS region, for the awslogs driver."
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ARN."
  type        = string
}

variable "namespace_id" {
  description = "Cloud Map private DNS namespace id."
  type        = string
}

variable "internal_domain" {
  description = "The private DNS suffix, e.g. martensa.internal. Used to build this service's base URL."
  type        = string
}

variable "execution_role_arn" {
  description = "The ECS agent's role."
  type        = string
}

variable "task_role_arn" {
  description = "The application's role."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets to place tasks in."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for the task's ENI."
  type        = list(string)
}

variable "image" {
  description = <<-EOT
    Full image reference, including the tag.

    Must be an immutable tag - a commit SHA, not `latest`. The ECR repositories are configured
    IMMUTABLE precisely so this cannot silently change meaning between a plan and an apply.
  EOT
  type        = string
}

variable "container_port" {
  description = "The port the service listens on: 9000 for the gateway, 9001-9006 for the services."
  type        = number

  validation {
    condition     = var.container_port > 1024 && var.container_port < 65536
    error_message = "container_port must be an unprivileged port."
  }
}

variable "cpu" {
  description = "Task CPU units. 512 = half a vCPU, which is enough for a Spring Boot service at this traffic."
  type        = number
  default     = 512
}

variable "memory" {
  description = <<-EOT
    Task memory in MiB. Must be a combination Fargate allows for the chosen CPU.

    1024 with 512 CPU is the smallest pairing that runs a Spring Boot service without the JVM
    fighting the container limit. Below it, the heap that MaxRAMPercentage picks plus metaspace
    plus the JVM's own overhead exceeds the limit, and the container is OOM-killed during
    start-up - which ECS reports as `OutOfMemoryError: Container killed due to memory usage`,
    the one message people reliably mistake for an application leak.
  EOT
  type        = number
  default     = 1024
}

variable "cpu_architecture" {
  description = "ARM64 for Graviton, ~20% cheaper. The image must be built for it."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "max_ram_percentage" {
  description = <<-EOT
    Fraction of the container's memory limit the JVM may use for the heap.

    75 rather than the JVM's default 25: a 1 GB task with a 256 MB heap wastes most of what it
    is billed for. Not higher - the remaining quarter is metaspace, thread stacks, direct byte
    buffers and the JVM itself, and squeezing it is what turns a healthy service into an
    OOM-kill under load.
  EOT
  type        = number
  default     = 75

  validation {
    condition     = var.max_ram_percentage > 0 && var.max_ram_percentage <= 90
    error_message = "max_ram_percentage must be between 1 and 90."
  }
}

variable "desired_count" {
  description = <<-EOT
    How many tasks to run.

    One is the default and is honest about what this is: a single task means a deployment or a
    Spot reclaim is a brief outage. Two is the first number that makes the service actually
    available, and it doubles the compute bill for that service.

    Zero is legitimate and useful - it stops a service without destroying anything, which is how
    an environment is parked between working sessions.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count cannot be negative."
  }
}

variable "capacity_provider" {
  description = "FARGATE_SPOT for stateless services, FARGATE for anything that must not be reclaimed."
  type        = string
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "environment" {
  description = "Plain environment variables. Anything secret belongs in `secrets` instead - these are visible in the console."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Environment variable name to Secrets Manager ARN. Resolved by the agent before the container starts."
  type        = map(string)
  default     = {}
}

variable "target_group_arn" {
  description = "Load balancer target group, or null. Only the gateway has one."
  type        = string
  default     = null
}

variable "health_check_grace_seconds" {
  description = <<-EOT
    How long to allow for start-up before health checks count.

    120 seconds because Flyway migrations run before the HTTP port opens, and a cold JVM on a
    burstable task is slow. Too low and ECS kills the task mid-migration, restarts it, and the
    symptom is a service that never stabilises with nothing in the log to explain why.
  EOT
  type        = number
  default     = 120
}

variable "stop_timeout_seconds" {
  description = <<-EOT
    How long ECS waits after SIGTERM before SIGKILL.

    Must exceed the service's `timeout-per-shutdown-phase` (25s in the aws profile) or graceful
    shutdown is pointless: in-flight requests are severed anyway and every rolling deploy
    produces a handful of 502s.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.stop_timeout_seconds >= 30 && var.stop_timeout_seconds <= 120
    error_message = "stop_timeout_seconds must be between 30 (above the services' 25s shutdown phase) and 120 (Fargate's maximum)."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Never leave this unset - the default is 'never expire', which bills for ever."
  type        = number
  default     = 30
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command`. The only way into a task in a private subnet with no bastion."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
