/**
 * The VPC everything else sits in, and the reason it has no NAT Gateway.
 *
 * A NAT Gateway is $0.045 per hour before a byte of traffic - about $32 a month, per
 * availability zone, permanently, for a platform that is not serving anyone. It exists to give
 * private subnets outbound internet access, and the only outbound calls these tasks make are to
 * AWS itself: pulling an image from ECR, writing logs, reading a secret. Every one of those has
 * an interface endpoint, which is billed per hour at a fraction of the cost and never leaves
 * Amazon's network.
 *
 * So: private subnets with no route to the internet, and VPC endpoints for what the tasks
 * actually need. That is cheaper *and* a tighter boundary - a task that cannot reach the
 * internet cannot exfiltrate to it either.
 *
 * The one thing that breaks without care here is the ECR image pull. It needs THREE endpoints,
 * not one: `ecr.api` to authenticate, `ecr.dkr` to talk to the registry, and **S3**, because
 * image layers are stored in S3 and the registry hands out S3 URLs. Miss the S3 endpoint and
 * `docker pull` authenticates cleanly and then hangs on the first layer - which reads like a
 * network fault rather than a missing route, and is the single most common way a no-NAT ECS
 * setup fails.
 */

locals {
  # Carved from a /16 so each /24 is legible: .0 public, .10+ private. Room for 250 addresses
  # per subnet, which is far more than a handful of Fargate tasks will ever want, and leaves
  # the numbering obvious when a second AZ is switched on.
  public_subnets  = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 8, index)]
  private_subnets = [for index in range(var.availability_zone_count) : cidrsubnet(var.cidr_block, 8, index + 10)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # Both required for VPC *interface* endpoints to resolve. Without DNS hostnames the endpoint
  # gets no private DNS name, so `ecr.eu-central-1.amazonaws.com` keeps resolving to the public
  # address - which has no route, so the call times out rather than failing. Same silent hang
  # as a missing endpoint, with the endpoint sitting there looking correct.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc" })
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

# Public: the load balancer only. Nothing that holds data or runs application code goes here.
resource "aws_subnet" "public" {
  count = var.availability_zone_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}

# Private: every task, the database, the cache, the broker. No route to an internet gateway,
# so nothing in here is reachable from outside the VPC no matter what a security group says.
# That is the property worth having - a security group is a rule someone can widen by accident,
# a missing route is not.
resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  })
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Deliberately has no 0.0.0.0/0 route. The local VPC route is implicit and is all these
# subnets get - everything else goes through an endpoint or does not go.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# VPC endpoints - what replaces the NAT Gateway
# ---------------------------------------------------------------------------

# S3 is a *gateway* endpoint: a route table entry, not an ENI, and it costs nothing at all.
# Required for ECR image pulls, as above, and used by anything writing to a bucket.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3" })
}

# The interface endpoints. Each is an ENI in every private subnet, billed per hour - so the
# list is exactly what the tasks call and nothing speculative.
#
#   ecr.api / ecr.dkr  - pulling images
#   logs               - the awslogs driver. Without it a task starts, runs and logs nothing,
#                        and the failure is invisible because the thing that would have told
#                        you is the log driver itself
#   secretsmanager     - task definitions resolve secret ARNs at start-up. Missing this stops
#                        the task before the container ever runs, with a pull-secret error
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.key, ".", "-")}" })
}

# ---------------------------------------------------------------------------
# Security groups: the chain that keeps services unreachable from outside
# ---------------------------------------------------------------------------

# Endpoints accept HTTPS from inside the VPC only. Scoped to the VPC CIDR rather than to each
# task's security group because every task needs them and the endpoint is not a service anyone
# can reach from outside anyway.
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-endpoints"
  description = "HTTPS to VPC interface endpoints, from inside the VPC only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-endpoints" })
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "The only thing on this platform the internet may talk to"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Port 80 exists only to redirect to 443 - see the alb module. Serving anything real here
  # would mean a bearer token crossing the internet in clear text.
  ingress {
    description = "HTTP, redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To the gateway task"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

# The gateway: reachable from the load balancer and from nowhere else.
resource "aws_security_group" "gateway" {
  name        = "${var.name_prefix}-gateway"
  description = "The API gateway task"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}

# The six services. Reachable from the gateway and from each other - Orders calls Cart, Catalog
# and Inventory over REST - but never from the load balancer.
#
# **This is what makes "not routed at the gateway" a security control rather than an omission.**
# A service endpoint the gateway does not expose is not merely undocumented; there is no network
# path to it at all.
resource "aws_security_group" "service" {
  name        = "${var.name_prefix}-service"
  description = "The six application services; no path from the load balancer"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-service" })
}

# Rules are separate resources rather than inline blocks on purpose: two security groups that
# reference each other cannot be expressed inline without a cycle, and Terraform reports that
# as an unhelpful "Cycle:" listing every resource involved.
resource "aws_vpc_security_group_ingress_rule" "gateway_from_alb" {
  security_group_id            = aws_security_group.gateway.id
  description                  = "The load balancer, on the gateway's port"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.gateway_port
  to_port                      = var.gateway_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "service_from_gateway" {
  security_group_id            = aws_security_group.service.id
  description                  = "The gateway, on any service port"
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 9001
  to_port                      = 9006
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "service_from_service" {
  security_group_id            = aws_security_group.service.id
  description                  = "Service-to-service REST: Orders calls Cart, Catalog and Inventory"
  referenced_security_group_id = aws_security_group.service.id
  from_port                    = 9001
  to_port                      = 9006
  ip_protocol                  = "tcp"
}

# Egress is open, and that is not the hole it looks like: the private subnets have no route to
# the internet, so "anywhere" means "anywhere in this VPC, plus the endpoints". Narrowing it
# per destination would add rules that duplicate what routing already enforces.
resource "aws_vpc_security_group_egress_rule" "gateway_all" {
  security_group_id = aws_security_group.gateway.id
  description       = "Services, endpoints and the broker - all inside the VPC"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "service_all" {
  security_group_id = aws_security_group.service.id
  description       = "Database, cache, broker, endpoints - all inside the VPC"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
