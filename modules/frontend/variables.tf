variable "name_prefix" {
  description = "Prefix for CloudFront resource names, e.g. martensa-dev."
  type        = string
}

variable "bucket_name" {
  description = <<-EOT
    S3 bucket name. Globally unique across every AWS account, so include the account id or a
    suffix - `martensa-storefront` is long gone.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters, lowercase letters, digits, dots and hyphens, starting and ending alphanumeric."
  }
}

variable "domain_names" {
  description = <<-EOT
    Custom domains served by the distribution, e.g. ["martensa.ro", "www.martensa.ro"].

    Empty uses the generated *.cloudfront.net name. Every entry must be covered by
    certificate_arn, or CloudFront rejects the distribution outright.
  EOT
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = <<-EOT
    ACM certificate for the custom domains, or null.

    **Must be issued in us-east-1**, regardless of where everything else lives - CloudFront is a
    global service and reads certificates only from there. This is a different certificate from
    the load balancer's, which must be in the ALB's own region; the same domain needs both.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.certificate_arn == null || can(regex("^arn:aws:acm:us-east-1:", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate in us-east-1. CloudFront cannot read certificates from any other region."
  }
}

variable "price_class" {
  description = <<-EOT
    Which edge locations serve the site.

    PriceClass_100 is Europe and North America, and it is the cheapest. The customers are in
    Vrancea; paying for edge locations in Asia and South America buys latency nobody experiences.
  EOT
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "versioning_enabled" {
  description = "Keep previous object versions. Protection against a bad sync, not the rollback mechanism."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to empty the bucket. Safe - the contents are a build artefact."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
