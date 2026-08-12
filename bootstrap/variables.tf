variable "region" {
  description = "Region for the state bucket. Keep it the same as the infrastructure it describes."
  type        = string
  default     = "eu-central-1"
}

variable "bucket_name" {
  description = <<-EOT
    Name for the state bucket. Globally unique across every AWS account, so append the account
    id: `martensa-tfstate-123456789012`.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters, lowercase letters, digits, dots and hyphens."
  }
}

variable "state_version_retention_days" {
  description = <<-EOT
    How long a superseded state version is kept.

    90 days, because the mistake this protects against is usually noticed late - a resource
    removed from state weeks ago, discovered when something that depended on it breaks.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.state_version_retention_days >= 30
    error_message = "Keep at least 30 days of state history; a shorter window makes recovery from a late-discovered mistake impossible."
  }
}
