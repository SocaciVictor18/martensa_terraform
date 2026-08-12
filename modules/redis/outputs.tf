output "host" {
  description = "Primary endpoint hostname, for Cart's REDIS_HOST."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "Redis port, for Cart's REDIS_PORT."
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "The cache's security group."
  value       = aws_security_group.redis.id
}
