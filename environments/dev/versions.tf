terraform {
  # 1.5 is the floor because `import` blocks and the `check` block arrived there, and because
  # anything older cannot read the `moved` blocks a refactor of these modules would need.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # Pessimistic to the major version: 5.x brought `manage_master_user_password`, the
      # `aws_vpc_security_group_*_rule` resources used throughout, and OAC. A jump to 6.x is a
      # deliberate upgrade with its own plan, not something a fresh `init` should do on its own.
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Values are supplied by `terraform init -backend-config=backend.hcl`, not written here.
  #
  # **The backend block cannot use variables.** It is read before Terraform evaluates anything,
  # so `bucket = var.state_bucket` fails with "Variables not allowed" - which is the single most
  # common first stumble with remote state. Keeping the values in a separate file also stops the
  # account id from being committed.
  backend "s3" {}
}
