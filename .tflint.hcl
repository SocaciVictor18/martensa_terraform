config {
  call_module_type = "all"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # "deep" would call the AWS API to check that instance types, AMIs and IAM policies actually
  # exist. Genuinely useful, and deliberately off: it needs credentials, which makes linting a
  # thing that cannot run in a pull request from a fork or on a machine with no account.
}

# Every variable needs a description. Not style - a module input whose meaning lives only in the
# head of whoever wrote it is the reason infrastructure code rots faster than application code.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# snake_case for resource and variable names, so nothing is addressed two ways.
rule "terraform_naming_convention" {
  enabled = true
}

# A provider without a version constraint resolves to whatever is newest at `init` time, so two
# people initialising a week apart get different providers - and the plan differs for reasons
# neither of them changed.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# Off. It wants every module block to carry a version, which applies to registry modules; every
# module here is a local path, where a version means nothing.
rule "terraform_module_pinned_source" {
  enabled = false
}
