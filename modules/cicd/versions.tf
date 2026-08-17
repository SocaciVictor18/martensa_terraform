# A module without its own `required_providers` inherits whatever the caller happens to have, so a
# module that works here silently breaks when reused from a configuration pinned differently - and
# the error names a missing argument rather than a provider version.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
