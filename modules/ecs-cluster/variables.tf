variable "name_prefix" {
  description = "Cluster name and prefix for the IAM roles."
  type        = string
}

variable "region" {
  description = "AWS region, for scoping the secrets policy by ARN."
  type        = string
}

variable "account_id" {
  description = "AWS account id, for scoping the secrets policy by ARN."
  type        = string
}

variable "vpc_id" {
  description = "The VPC the private DNS namespace is associated with."
  type        = string
}

variable "internal_domain" {
  description = <<-EOT
    The private DNS zone services resolve each other through, e.g. martensa.internal.

    Must not be a domain that resolves publicly. A private zone shadows the public one inside
    the VPC, so using a real domain here makes every lookup for it - including ones meant to go
    to the internet - return an internal address instead.
  EOT
  type        = string
  default     = "martensa.internal"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*\\.(internal|local)$", var.internal_domain))
    error_message = "internal_domain must end in .internal or .local, so it cannot collide with a public zone."
  }
}

variable "container_insights" {
  description = <<-EOT
    Per-task CPU and memory metrics in CloudWatch.

    Costs a few dollars a month at this scale and is worth it: without it, a task being killed
    for memory and a task failing its health check look identical from outside.
  EOT
  type        = bool
  default     = true
}

variable "use_fargate_spot" {
  description = <<-EOT
    Run tasks on spare capacity at roughly a 70% discount.

    The trade is a two-minute termination notice: AWS can reclaim the task, and ECS starts a
    replacement. Every service here tolerates that - they are stateless, the Kafka consumers are
    idempotent by contract, and the outbox claim uses SKIP LOCKED so an interrupted publish is
    re-claimed. The **broker** is the exception and must not run on Spot; the kafka module pins
    itself to on-demand for that reason.
  EOT
  type        = bool
  default     = true
}

variable "additional_secret_arns" {
  description = "Secret ARNs outside the name_prefix namespace, e.g. the RDS-managed master credential."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
