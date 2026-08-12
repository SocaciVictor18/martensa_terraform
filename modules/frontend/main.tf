/**
 * The storefront: a private S3 bucket behind CloudFront.
 *
 * `martensa-frontend` is a Vite build - static files, no server - so there is nothing to run and
 * nothing to pay for beyond storage and transfer. That is also why the frontend never appears
 * in ECS; choosing Vite over Next.js was partly this, and the blueprint records the trade.
 *
 * ## The bucket is private, and CloudFront reaches it through OAC
 *
 * Origin Access Control signs CloudFront's requests to S3 with SigV4, so the bucket policy can
 * name the distribution and refuse everyone else. The bucket has no website endpoint and no
 * public read.
 *
 * The alternative - a public bucket with static website hosting - is simpler and wrong in a way
 * that does not show: the bucket's own URL keeps working, so every file stays reachable without
 * passing through CloudFront. That bypasses the security headers below, the TLS policy, and any
 * WAF attached later, and nothing in the application would ever notice.
 *
 * OAC rather than the older OAI, which AWS has deprecated and which cannot sign requests to
 * buckets using SSE-KMS.
 */

resource "aws_s3_bucket" "site" {
  bucket = var.bucket_name

  # Overridable, because a `terraform destroy` that fails on a bucket holding a JavaScript
  # bundle is pure obstacle - nothing here is not rebuilt by `npm run build`.
  force_destroy = var.force_destroy

  tags = merge(var.tags, { Name = var.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  # All four. Any one left false is enough for a later `aws s3 cp --acl public-read` to make an
  # object world-readable, which is how a "private" bucket ends up serving directly.
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    # ACLs off entirely. Ownership is the bucket's, permissions are the policy's, and there is
    # no second mechanism that can quietly disagree with it.
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    # A rollback is `aws s3 sync` of the previous build, so versioning is not the recovery
    # mechanism here - it is protection against a sync that deletes more than it meant to.
    status = var.versioning_enabled ? "Enabled" : "Disabled"
  }
}

# ---------------------------------------------------------------------------
# CloudFront
# ---------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-storefront"
  description                       = "SigV4-signed access from CloudFront to the private storefront bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Sent on every response. The storefront handles addresses and card redirects, and these are the
# headers a static site can carry without a server in front of it.
resource "aws_cloudfront_response_headers_policy" "site" {
  name    = "${var.name_prefix}-storefront"
  comment = "Security headers for the Martensa storefront"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }

    content_type_options {
      # Stops a browser guessing that a .json is really HTML and running it.
      override = true
    }

    frame_options {
      # Clickjacking: without it the shop can be framed invisibly over an attacker's page, and
      # the customer's clicks land on real buttons.
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      # Origin to third parties, full path only to ourselves. A product URL leaking into a
      # referrer header is a small privacy loss that costs nothing to avoid.
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }

  # CSP is deliberately NOT set here, and it is a gap rather than a decision. The storefront
  # calls the gateway on another origin and loads map tiles from OpenStreetMap, so a correct
  # policy has to name both - and a wrong one breaks the map or the API with a console error
  # nobody sees until a customer reports a blank page. It belongs in the change that can test it
  # against the running site.
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name_prefix} storefront"
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = var.domain_names

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "storefront"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "storefront"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed policy ids, which are account-independent constants:
    #   CachingOptimized - honours Cache-Control, which Vite's hashed filenames make safe
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  # React Router owns the URL space. Without these, /produse/lapte asks S3 for an object that
  # does not exist and the customer gets CloudFront's XML error document - so every deep link,
  # every bookmark and every refresh outside "/" breaks, while the site works perfectly when
  # navigated from the home page.
  dynamic "custom_error_response" {
    for_each = [403, 404]

    content {
      error_code         = custom_error_response.value
      response_code      = 200
      response_page_path = "/index.html"
      # Short, so a genuinely missing asset is retried rather than negatively cached for hours.
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # The default CloudFront certificate covers *.cloudfront.net only, so a custom domain needs
    # its own ACM certificate - and that certificate must be in **us-east-1** wherever the rest
    # of this lives. CloudFront is global and reads certificates from there alone; one issued in
    # eu-central-1 is rejected with an error that names neither region.
    cloudfront_default_certificate = var.certificate_arn == null
    acm_certificate_arn            = var.certificate_arn
    ssl_support_method             = var.certificate_arn == null ? null : "sni-only"
    minimum_protocol_version       = var.certificate_arn == null ? "TLSv1" : "TLSv1.2_2021"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-storefront" })
}

# ---------------------------------------------------------------------------
# The bucket policy that makes OAC work
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "site" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Scoped to this distribution. Without the condition the statement reads "any CloudFront
    # distribution in any AWS account may read this bucket" - which is a real, exploitable
    # misconfiguration rather than a theoretical one: anyone can create a distribution.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site.json

  # The public access block must be in place before a policy is attached, or S3 evaluates the
  # policy against a bucket that is still publicly configurable.
  depends_on = [aws_s3_bucket_public_access_block.site]
}
