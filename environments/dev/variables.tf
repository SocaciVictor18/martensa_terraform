variable "region" {
  description = "AWS region for everything except the CloudFront certificate, which must be us-east-1."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name, used in the resource prefix and in the default tags."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,10}$", var.environment))
    error_message = "environment must be lowercase letters and digits, 2-11 characters."
  }
}

variable "availability_zone_count" {
  description = <<-EOT
    Availability zones to spread across.

    **Two, not one, despite the cost brief.** An internet-facing ALB requires subnets in at least
    two zones - AWS rejects it otherwise - so one is not an option while there is a load
    balancer. The saving comes from having no NAT Gateway rather than from having one zone; the
    second zone's cost here is the extra interface endpoints, a few dollars a month.
  EOT
  type        = number
  default     = 2
}

variable "storefront_bucket_name" {
  description = "Globally unique S3 bucket name for the built storefront."
  type        = string
}

variable "storefront_domains" {
  description = "Custom domains for the storefront, or [] to use the generated CloudFront name."
  type        = list(string)
  default     = []
}

variable "storefront_certificate_arn" {
  description = "ACM certificate for storefront_domains. Must be in us-east-1. Null uses the default CloudFront certificate."
  type        = string
  default     = null
}

variable "api_certificate_arn" {
  description = "ACM certificate for the API load balancer, in `region`. Required - the listener is HTTPS only."
  type        = string
}

variable "api_domain" {
  description = <<-EOT
    Public hostname for the API, e.g. api.martensa.ro.

    Used to build CORS_ALLOWED_ORIGINS and the storefront's own origin. A DNS record pointing it
    at the load balancer is not created here: the hosted zone may live in another account, and a
    record Terraform writes into a zone it does not own fails in a way that is tedious to unpick.
  EOT
  type        = string
}

variable "images" {
  description = <<-EOT
    Image reference per service, including an immutable tag.

    Terraform sets the first revision; CI registers every one after that, which is why the ECS
    services ignore changes to `task_definition`. Bootstrapping needs *something* to point at,
    and a repository with no image yet means a task that cannot start - so the first apply
    normally runs after CI has pushed once.
  EOT
  type        = map(string)
}

variable "desired_counts" {
  description = <<-EOT
    Tasks per service. Zero parks a service without destroying it.

    One is honest for an environment nobody is serving from: a deployment or a Spot reclaim is a
    brief outage. Two is the first number that makes a service actually available.
  EOT
  type        = map(number)
  default     = {}
}

variable "google_client_id" {
  description = <<-EOT
    Google OAuth client id for "Continuă cu Google".

    Public by design - it is compiled into the storefront's JavaScript and appears in every
    authorisation URL. It is a plain environment variable rather than a secret for that reason.
    Blank disables the endpoint, which then answers 503 rather than pretending to verify.
  EOT
  type        = string
  default     = ""
}

variable "bootstrap_admin_user_id" {
  description = <<-EOT
    UUID of an already-registered account to promote to ROLE_ADMIN at start-up.

    By id rather than by email, which was a finding from the security review: an email can be
    claimed by whoever registers it first, so bootstrapping by email is a race for
    administrator. Blank disables it, which is the correct steady state.
  EOT
  type        = string
  default     = ""
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database at the API level."
  type        = bool
  default     = true
}

variable "db_skip_final_snapshot" {
  description = "Allow `terraform destroy` to drop the database without a final snapshot. Scratch environments only."
  type        = bool
  default     = false
}

variable "alb_deletion_protection" {
  description = "Refuse to delete the load balancer. Its DNS name is what everything points at."
  type        = bool
  default     = true
}

variable "use_fargate_spot" {
  description = "Run the application services on spare capacity at roughly a 70% discount. The broker never uses it."
  type        = bool
  default     = true
}
