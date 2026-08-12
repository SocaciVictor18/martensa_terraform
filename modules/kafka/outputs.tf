output "bootstrap_servers" {
  description = <<-EOT
    What every service puts in KAFKA_BOOTSTRAP_SERVERS.

    This is also the value the broker advertises, and the two must be the same string - a client
    that bootstraps against one name and is redirected to another resolves the second one, which
    is where a working connection turns into a send that times out.
  EOT
  value       = "${local.advertised_host}:9092"
}

output "security_group_id" {
  description = "The broker's security group."
  value       = aws_security_group.broker.id
}

output "file_system_id" {
  description = "EFS filesystem holding the log directories. Destroying it destroys every topic and every consumer offset."
  value       = aws_efs_file_system.kafka.id
}

output "log_group_name" {
  description = "The broker's CloudWatch log group."
  value       = aws_cloudwatch_log_group.kafka.name
}
