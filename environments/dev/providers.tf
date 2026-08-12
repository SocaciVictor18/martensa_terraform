provider "aws" {
  region = var.region

  default_tags {
    # Applied to every resource that supports tagging, so nothing has to remember. These are the
    # tags that answer the two questions a monthly bill raises: what is this, and can it be
    # switched off.
    tags = {
      Project     = "martensa"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "martensa_terraform"
    }
  }
}

# Credentials are never configured here. They come from the environment - AWS_PROFILE, or the
# OIDC role a GitHub Actions workflow assumes. An `access_key` in a provider block is a
# long-lived credential in version control, and it is in the state file too.

data "aws_caller_identity" "current" {}
