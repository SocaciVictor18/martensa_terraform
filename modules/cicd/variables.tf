variable "name_prefix" {
  description = "Prefix for every resource name, e.g. martensa-dev."
  type        = string
}

variable "github_owner" {
  description = <<-EOT
    The GitHub user or organisation that owns the repositories allowed to deploy.

    Always a literal in the trust policy - never a wildcard. Combined with `repositories` it is
    what stops any repository on GitHub from minting a token this role accepts, which is the
    failure this whole module is shaped around.
  EOT
  type        = string
}

variable "repositories" {
  description = <<-EOT
    Repository names, without the owner, allowed to assume the deploy role.

    One entry per repository that actually deploys something. A repository absent from this list
    cannot assume the role however many secrets it holds - which is the point, and the reason
    adding a service means adding it here rather than only in CI.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.repositories) > 0
    error_message = "At least one repository must be allowed, or the role can never be assumed."
  }

  validation {
    condition     = alltrue([for r in var.repositories : !can(regex("[*?/]", r))])
    error_message = "Repository names must not contain wildcards or a slash - the owner is prepended and a wildcard here would widen the trust policy."
  }
}

variable "deploy_branch" {
  description = <<-EOT
    The single branch a deploy may run from.

    Pinned rather than left open because a workflow file is part of the branch it runs on: without
    this, opening a pull request from a fork - or pushing any branch - would be enough to run an
    edited workflow with this role's permissions.
  EOT
  type        = string
  default     = "main"
}

variable "ecr_repository_arns" {
  description = "The repositories this role may push to. Scoped, so ECR login is not ECR write."
  type        = list(string)
}

variable "ecs_cluster_arn" {
  description = "The only cluster this role may deploy to."
  type        = string
}

variable "passable_role_arns" {
  description = <<-EOT
    The task and execution roles a registered task definition may name.

    **The single most important variable here.** Unrestricted `iam:PassRole` alongside
    `RegisterTaskDefinition` is permission to run a container as any role in the account, which
    turns a compromised workflow into an account takeover through a path that looks like a
    deployment. A service with its own task role has to be added here; forgetting produces an
    explicit AccessDenied naming the role, which is the right way round.
  EOT
  type        = list(string)
}

variable "storefront_bucket_arn" {
  description = "The bucket holding the built storefront."
  type        = string
}

variable "storefront_distribution_arn" {
  description = "The CloudFront distribution to invalidate after an upload."
  type        = string
}

variable "tags" {
  description = "Tags applied to everything this module creates."
  type        = map(string)
  default     = {}
}
