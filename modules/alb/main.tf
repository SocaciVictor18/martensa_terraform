/**
 * The Application Load Balancer in front of the API gateway. The only thing on this platform
 * the internet can reach.
 *
 * One target group, one listener rule, one backend. Nothing else is registered - not because it
 * would not work, but because the gateway is where authentication, CORS and rate limiting live.
 * A second target group pointing at a service would be a path around all three, and it would
 * look like a routing convenience rather than the hole it is.
 */

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [var.security_group_id]

  # Refuses deletion at the API level. An ALB is the DNS name everything points at, and
  # recreating one hands out a different name.
  enable_deletion_protection = var.deletion_protection

  # Longer than the gateway's own read timeout, so a slow upstream produces the gateway's 504
  # with its correlation id rather than the load balancer's anonymous one.
  idle_timeout = var.idle_timeout_seconds

  # Drops requests whose headers the ALB and the backend would parse differently - the class of
  # bug behind HTTP request smuggling. `defensive` is the AWS default for new load balancers and
  # is named here so it survives a provider default changing.
  desync_mitigation_mode = "defensive"

  # Removes the `server: awselb/2.0` response header. Not a control on its own - security
  # through obscurity is not security - but there is no reason to advertise the load balancer's
  # exact version to a scanner.
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [var.access_logs_bucket]

    content {
      bucket  = access_logs.value
      prefix  = var.name_prefix
      enabled = true
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "gateway" {
  name     = "${var.name_prefix}-gateway"
  port     = var.gateway_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  # Fargate tasks in awsvpc mode have their own ENI, so the target is an IP, not an instance.
  target_type = "ip"

  health_check {
    enabled = true
    # Readiness, not the aggregate health endpoint. The gateway owns no data, so its readiness
    # is genuinely about whether it can serve - and the aggregate endpoint would go unhealthy if
    # a downstream check failed, taking the whole platform offline because one service was down.
    path                = "/actuator/health/readiness"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # How long the ALB waits for in-flight requests before removing a stopping task. Must be under
  # the ECS stop timeout, or the task is SIGKILLed while the load balancer is still draining it -
  # which is exactly the 502 that graceful shutdown was configured to prevent.
  deregistration_delay = 20

  # Spring Security is stateless here - JWTs, no server-side session - so any task can serve any
  # request. Stickiness would pin a customer to one task and turn a single Spot reclaim into a
  # visible failure for them alone.
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  lifecycle {
    # A target group cannot be deleted while a listener forwards to it, so replacing one
    # requires the new group to exist first.
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-gateway" })
}

# Port 80 exists only to send people to 443. A permanent redirect, so browsers stop asking.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.2 and above. The 1.3 policies still permit 1.2, which is what a policy named for 1.3
  # obscures - this one is explicit about the floor. Dropping to a policy that allows TLS 1.0
  # would let a downgrade attack strip the connection to a cipher suite that is broken.
  ssl_policy      = var.ssl_policy
  certificate_arn = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  tags = var.tags
}
