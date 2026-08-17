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

# ---------------------------------------------------------------------------
# The notification service
# ---------------------------------------------------------------------------

variable "notification_mail_from" {
  description = <<-EOT
    The address every message is sent from, and the SES identity this platform may send as.

    **Its domain has to be verified in SES out of band, and Terraform deliberately does not do
    it.** Verification is a DNS record on a zone this configuration does not manage - the
    storefront's domain is a variable here, not a Route 53 zone - so an `aws_ses_domain_identity`
    resource would create an identity stuck in `Pending` for ever and report success. Worse, it
    would make `terraform destroy` remove a verification that took a DNS propagation to earn.

    The domain half of this value is also what the task role's SES policy is scoped to, so
    changing it changes what the service is permitted to send as. The two cannot drift, which is
    the reason the policy derives the domain from here rather than taking its own variable.

    Until the domain is verified **and** the account is out of the SES sandbox, sends fail with
    `MessageRejected` - and in the sandbox they fail for every recipient that is not itself
    verified, which looks exactly like a bug in the recipient lookup.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:].]+[.][^@[:space:]]+$", var.notification_mail_from))
    error_message = "notification_mail_from must be a single email address - its domain is used to scope the SES policy."
  }
}

variable "notification_mail_from_name" {
  description = "The display name beside the from-address. What a recipient's inbox shows before they open anything."
  type        = string
  default     = "Martensa"
}

variable "notification_mail_reply_to" {
  description = <<-EOT
    Where a customer's reply goes.

    Different from the from-address on purpose: that one is a no-reply sender the platform owns,
    and this is a mailbox somebody reads. A message whose Reply-To lands in the same unattended
    no-reply inbox is how a customer's question about their order disappears.
  EOT
  type        = string
}

variable "notification_admin_alerts" {
  description = <<-EOT
    Where the low-stock alert goes. A human's inbox, or blank.

    Blank is a supported state rather than a misconfiguration: the alert is queued, found to have
    nowhere to go, and abandoned with a warning naming this property. That is the right answer to
    "nobody asked for these" - the alternative would let a missing property here dead-letter an
    event on Inventory's topic.
  EOT
  type        = string
  default     = ""
}
