output "service_name" {
  description = "The ECS service name, which is also its internal DNS label."
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "The revision Terraform created. CI registers newer ones; this is only the starting point."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group, for `aws logs tail`."
  value       = aws_cloudwatch_log_group.this.name
}

output "internal_hostname" {
  description = "How other services reach this one, e.g. users.martensa.internal."
  value       = "${var.service_name}.${var.internal_domain}"
}

output "base_url" {
  description = "The full http://host:port another service puts in its *_BASE_URL environment variable."
  value       = "http://${var.service_name}.${var.internal_domain}:${var.container_port}"
}
