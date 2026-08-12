/**
 * The S3 bucket that holds every other configuration's state.
 *
 * ## Why this is separate, and why its own state is local
 *
 * A configuration cannot store its state in a bucket it is also creating: `init` needs the
 * backend to exist before the first `apply` can create it. So this one runs once, with local
 * state, and everything else uses the bucket it produces.
 *
 * The resulting `terraform.tfstate` here is committed **nowhere** - it is in .gitignore - but it
 * is also nearly worthless to lose. It describes one bucket. If it disappears, `terraform
 * import` recovers it in a minute, which is why the usual advice to migrate this state into its
 * own bucket afterwards is more ceremony than it is worth at this size.
 *
 * ## What matters here
 *
 * The state file contains the per-service database passwords in plain text. Not because
 * anything writes them there deliberately, but because Terraform records every attribute of
 * every resource it manages, and `random_password.result` is an attribute. Everything below
 * follows from that: encryption, versioning, blocked public access, and a policy that refuses
 * unencrypted transport.
 */

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "martensa"
      ManagedBy = "terraform"
      Purpose   = "terraform-state"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = var.bucket_name

  # Never true. A state bucket emptied by a `terraform destroy` in this directory takes every
  # other environment's state with it, and the resources those states describe become
  # unmanaged - still running, still billed, invisible to Terraform.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = var.bucket_name }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    # **The single most important setting in this file.** A corrupted or truncated state write
    # is otherwise unrecoverable, and the failure mode is total: Terraform no longer knows what
    # it manages, so the next plan proposes creating everything that already exists. With
    # versioning, the fix is restoring the previous object.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    # S3 encrypts with the bucket key rather than calling KMS per object. Irrelevant to security
    # with AES256; it matters if this is ever moved to SSE-KMS, where per-object calls dominate
    # the cost of a chatty state file.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Old state versions accumulate on every apply. Kept long enough to recover from a mistake
# noticed weeks later, expired after that so the bucket does not grow without limit.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    # Refuses plain HTTP. Bucket encryption protects the object at rest; this protects it in
    # transit, and without it a state file full of database passwords can be fetched over an
    # unencrypted connection by anything holding valid credentials.
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
