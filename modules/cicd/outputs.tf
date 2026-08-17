output "deploy_role_arn" {
  description = <<-EOT
    What a workflow puts in `role-to-assume`.

    Not a secret: it is an ARN, it is useless without a token minted by one of the repositories
    named in the trust policy, and putting it in a GitHub secret only makes it harder to see which
    role a workflow actually uses.
  EOT
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "The GitHub OIDC provider. One per account - a second environment imports this rather than creating another."
  value       = aws_iam_openid_connect_provider.github.arn
}
