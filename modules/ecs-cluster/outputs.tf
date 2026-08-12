output "cluster_id" {
  description = "The cluster ARN, which is what aws_ecs_service wants."
  value       = aws_ecs_cluster.this.id
}

output "cluster_name" {
  description = "The cluster's plain name, for the CLI and for CI deployments."
  value       = aws_ecs_cluster.this.name
}

output "execution_role_arn" {
  description = "The ECS agent's role: pulls images, reads secrets, writes logs."
  value       = aws_iam_role.execution.arn
}

output "task_role_arn" {
  description = "The application's role. Holds no permissions, on purpose."
  value       = aws_iam_role.task.arn
}

output "namespace_id" {
  description = "Cloud Map namespace id, for registering a service."
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "internal_domain" {
  description = "The private DNS suffix, e.g. martensa.internal."
  value       = aws_service_discovery_private_dns_namespace.this.name
}
