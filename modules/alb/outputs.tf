output "dns_name" {
  description = "The load balancer's hostname. Point a CNAME or a Route 53 alias at this."
  value       = aws_lb.this.dns_name
}

output "zone_id" {
  description = "Hosted zone id of the load balancer, for a Route 53 alias record."
  value       = aws_lb.this.zone_id
}

output "target_group_arn" {
  description = "The gateway's target group. Passed to the gateway's ECS service and to nothing else."
  value       = aws_lb_target_group.gateway.arn
}

output "arn" {
  description = "The load balancer ARN, for CloudWatch alarms on 5xx counts and target health."
  value       = aws_lb.this.arn
}
