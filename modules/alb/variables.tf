variable "name_prefix" {
  description = "Prefix for the load balancer and target group names."
  type        = string

  validation {
    condition     = length(var.name_prefix) <= 24
    error_message = "name_prefix must be 24 characters or fewer: ALB and target group names are capped at 32, and this module appends '-gateway'."
  }
}

variable "vpc_id" {
  description = "The VPC the target group resolves targets in."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer's nodes. At least two are required by AWS for an internet-facing ALB."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An internet-facing ALB requires subnets in at least two availability zones. Raise availability_zone_count in the network module to 2."
  }
}

variable "security_group_id" {
  description = "The ALB's security group: 80 and 443 from anywhere, egress to the VPC."
  type        = string
}

variable "gateway_port" {
  description = "The port the API gateway task listens on."
  type        = number
  default     = 9000
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for the HTTPS listener, in the same region as the load balancer.

    Not created here on purpose: issuing a certificate requires proving control of a domain, and
    a DNS validation record that Terraform writes into a zone it does not own will sit in
    `PENDING_VALIDATION` for ever while the apply hangs. Request it once, validate it, then pass
    the ARN in.
  EOT
  type        = string

  validation {
    condition     = can(regex("^arn:aws:acm:", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "ssl_policy" {
  description = "Predefined ALB security policy. The default forbids anything below TLS 1.2."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "idle_timeout_seconds" {
  description = "How long the ALB holds an idle connection. Above the gateway's own read timeout, so a slow upstream produces the gateway's error rather than the load balancer's."
  type        = number
  default     = 65
}

variable "deletion_protection" {
  description = "Refuse deletion at the API level. The ALB's DNS name is what everything points at, and a replacement gets a different one."
  type        = bool
  default     = true
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs, or null. The bucket policy must already allow the ELB service principal to write."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
