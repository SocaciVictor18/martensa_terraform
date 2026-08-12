output "repository_urls" {
  description = "Push target per service, e.g. 123456789012.dkr.ecr.eu-central-1.amazonaws.com/martensa-dev/users."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Per-service ARNs, for scoping a CI push policy to one repository at a time."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
