output "api_url" {
  description = "Where the storefront should point. Only reachable once api_domain resolves to alb_dns_name."
  value       = "https://${var.api_domain}"
}

output "alb_dns_name" {
  description = <<-EOT
    The load balancer's own hostname.

    `api_domain` has to be pointed at this with a CNAME, or a Route 53 alias if the zone is in
    this account. No record is created here - see the variable's description for why.

    Until that record exists, the load balancer answers on this name but the HTTPS listener
    presents a certificate for `api_domain`, so a browser refuses the connection with a name
    mismatch. That is expected, not a misconfiguration.
  EOT
  value       = module.alb.dns_name
}

output "storefront_url" {
  description = "The CloudFront hostname serving the built storefront."
  value       = "https://${module.frontend.domain_name}"
}

output "storefront_bucket" {
  description = "Deploy target: aws s3 sync dist/ s3://<this>/ --delete"
  value       = module.frontend.bucket_name
}

output "storefront_distribution_id" {
  description = "Needed for the cache invalidation that must follow every storefront deploy."
  value       = module.frontend.distribution_id
}

output "ecr_repository_urls" {
  description = "Push targets, per service."
  value       = module.ecr.repository_urls
}

output "ecs_cluster_name" {
  description = "For `aws ecs update-service` in CI, and for `aws ecs execute-command`."
  value       = module.ecs.cluster_name
}

output "kafka_bootstrap_servers" {
  description = "The broker address the services are configured with."
  value       = module.kafka.bootstrap_servers
}

output "database_endpoint" {
  description = "RDS endpoint. Not reachable from outside the VPC - see docs/infrastructure.md for how to connect."
  value       = module.database.endpoint
}

output "database_master_secret_arn" {
  description = "RDS-managed master credential, needed once to run the database bootstrap."
  value       = module.database.master_secret_arn
}

output "database_bootstrap_sql" {
  description = <<-EOT
    The SQL that creates the per-service databases and roles, with the generated passwords.

    Sensitive, so `terraform output` will not print it by accident. Read it with
    `terraform output -raw database_bootstrap_sql`.
  EOT
  value       = module.database.bootstrap_sql
  sensitive   = true
}

output "application_secret_arns" {
  description = <<-EOT
    Secrets whose values Terraform deliberately does not know.

    Every one holds the placeholder REPLACE-ME until it is filled in with
    `aws secretsmanager put-secret-value`. A service reading the placeholder starts and then
    rejects every request, which is the diagnosable failure - see secrets.tf.
  EOT
  value       = { for key, secret in aws_secretsmanager_secret.application : key => secret.arn }
}

output "internal_base_urls" {
  description = "How the services address each other. Useful when a base URL looks wrong in a task definition."
  value = {
    users     = module.users.base_url
    catalog   = module.catalog.base_url
    inventory = module.inventory.base_url
    cart      = module.cart.base_url
    orders    = module.orders.base_url
    payments  = module.payments.base_url
    gateway   = module.gateway.base_url
    # Listed for completeness, and nothing calls it. The notification service has no inbound
    # traffic from any other service - it is driven entirely by Kafka - and the gateway does not
    # route to it, which is the first lock on its admin endpoints.
    notification = module.notification.base_url
  }
}

output "internal_api_token_secret_arn" {
  description = <<-EOT
    The generated shared secret for `/api/internal/**`.

    Unlike `application_secret_arns` above, this one already holds a real value - Terraform
    generated it, for the reason set out in secrets.tf. It is an output so that a 401 between the
    notification service and Users can be diagnosed by reading the value the three task
    definitions were actually given, which is the question that failure always turns into.
  EOT
  value       = aws_secretsmanager_secret.internal_api_token.arn
}
