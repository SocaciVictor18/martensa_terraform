variable "name_prefix" {
  description = "Prefix for resource names, e.g. martensa-dev."
  type        = string
}

variable "region" {
  description = "AWS region, for the awslogs driver."
  type        = string
}

variable "vpc_id" {
  description = "The VPC the broker and its filesystem live in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets. One EFS mount target is created per subnet."
  type        = list(string)
}

variable "service_security_group_id" {
  description = "The only security group allowed to reach port 9092."
  type        = string
}

variable "cluster_id" {
  description = "ECS cluster ARN."
  type        = string
}

variable "namespace_id" {
  description = "Cloud Map namespace, where the broker registers as kafka.<internal_domain>."
  type        = string
}

variable "internal_domain" {
  description = "The private DNS suffix. Becomes part of the advertised listener, so it must match what clients resolve."
  type        = string
}

variable "execution_role_arn" {
  description = "The ECS agent's role."
  type        = string
}

variable "task_role_arn" {
  description = "The broker's role. Holds no permissions; EFS is mounted by the agent, not by the container."
  type        = string
}

variable "image" {
  description = <<-EOT
    Kafka image, pinned to an exact version.

    Not `:latest`. A broker that silently upgrades across a major version on the next task
    replacement can rewrite its log format, and the way you find out is a consumer failing to
    read records it wrote yesterday.
  EOT
  type        = string
  default     = "bitnami/kafka:3.9.0"

  validation {
    condition     = can(regex(":[^:]+$", var.image)) && !can(regex(":latest$", var.image))
    error_message = "image must carry an explicit version tag, and must not be ':latest'."
  }
}

variable "cpu" {
  description = "Task CPU units. 512 is half a vCPU and is ample for this volume."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Task memory in MiB. Kafka's throughput comes from the page cache, so the excess over the heap is doing real work."
  type        = number
  default     = 1024
}

variable "heap_mb" {
  description = <<-EOT
    JVM heap for the broker.

    Deliberately far below the task memory. Kafka serves reads from the operating system's page
    cache, not from its own heap, so memory given to the JVM is memory taken away from the
    thing that makes it fast. A large heap also lengthens garbage collection pauses, and a pause
    past the session timeout makes every consumer rebalance.
  EOT
  type        = number
  default     = 512

  validation {
    condition     = var.heap_mb >= 256
    error_message = "heap_mb must be at least 256."
  }
}

variable "retention_hours" {
  description = <<-EOT
    How long a topic keeps its records.

    168 hours is a week. This is also the window in which a new consumer group reading from
    `earliest` can backfill - Users' loyalty consumer did exactly that when it moved topics - so
    shortening it shortens how far back a rebuilt consumer can go.
  EOT
  type        = number
  default     = 168
}

variable "desired_count" {
  description = <<-EOT
    Broker tasks. One, or zero to park the environment.

    Must never exceed 1: a second task would take node id 1 and the same EFS log directory as
    the first. It is a number rather than a constant so an environment can be stopped without
    destroying the filesystem the topics live on.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.desired_count == 0 || var.desired_count == 1
    error_message = "desired_count must be 0 or 1. This is a single-broker design; two tasks would share a node id and a log directory."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the broker's own logs."
  type        = number
  default     = 30
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command`, which is how kafka-topics.sh gets run against this broker."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
