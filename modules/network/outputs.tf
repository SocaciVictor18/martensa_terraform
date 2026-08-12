output "vpc_id" {
  description = "The VPC everything else attaches to."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "The VPC's address range, for rules that scope to the whole network."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets for the load balancer. Nothing else belongs here."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Subnets for every task, the database, the cache and the broker."
  value       = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  description = "The only security group that accepts traffic from the internet."
  value       = aws_security_group.alb.id
}

output "gateway_security_group_id" {
  description = "For the gateway task. Accepts the load balancer and nothing else."
  value       = aws_security_group.gateway.id
}

output "service_security_group_id" {
  description = "For the six application tasks. No path from the load balancer exists."
  value       = aws_security_group.service.id
}
