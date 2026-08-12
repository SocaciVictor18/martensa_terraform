/**
 * One Spring Boot service on Fargate: log group, task definition, ECS service, Cloud Map
 * registration, and an optional load balancer attachment.
 *
 * Used seven times. Everything that differs between the services is a variable, and everything
 * that must not differ - the health check semantics, the log configuration, the deployment
 * circuit breaker - is fixed here. That is the point of the module: the seventh service cannot
 * quietly get a weaker deployment guard than the first.
 */

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}/${var.service_name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.service_name}", Service = var.service_name })
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.service_name}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    # ARM64. Fargate Graviton is about 20% cheaper than X86_64 for the same vCPU, and the JVM
    # has first-class ARM support - but the image must be built for it. A multi-arch build, or
    # `--platform linux/arm64`, is not optional: an amd64-only image fails at task start with
    # `image Manifest does not contain descriptor matching platform`, which reads like a corrupt
    # push rather than an architecture mismatch.
    cpu_architecture = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
          # Named so Cloud Map and the load balancer can refer to it symbolically rather than
          # by number in three places.
          name = "http"
        }
      ]

      environment = [
        for key, value in merge(
          {
            # Every service reads this to pick the aws profile. Without it Boot falls back to
            # the default profile, which starts Docker Compose support and tries to reach a
            # local Postgres - so the task starts, hangs on a connection that will never be
            # made, and is killed by the health check.
            SPRING_PROFILES_ACTIVE = "aws"
            # Container-aware heap sizing. The JVM reads the cgroup limit, but the default
            # MaxRAMPercentage of 25% leaves three quarters of a small Fargate task unused.
            JAVA_TOOL_OPTIONS = "-XX:MaxRAMPercentage=${var.max_ram_percentage}"
          },
          var.environment
        ) : { name = key, value = tostring(value) }
      ]

      # Injected by the agent from Secrets Manager before the container starts, so the value
      # never appears in the task definition, in the console, or in a `describe-tasks` response.
      secrets = [
        for key, arn in var.secrets : { name = key, valueFrom = arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        # Readiness, not liveness, and not `/actuator/health`. Readiness reports false while
        # Flyway is still migrating at start-up; the aggregate health endpoint can report UP
        # before the schema is ready, and the service then takes traffic it cannot serve.
        command  = ["CMD-SHELL", "curl -fsS http://localhost:${var.container_port}/actuator/health/readiness || exit 1"]
        interval = 30
        timeout  = 5
        retries  = 3
        # Generous, because a Spring Boot service on a small Fargate task takes 30-60 seconds to
        # start and Flyway runs before the port opens. Too short and ECS kills the task during
        # migration, restarts it, kills it again - a crash loop whose only symptom is a service
        # that never stabilises, with no error anywhere.
        startPeriod = var.health_check_grace_seconds
      }

      # The JVM's default is to leave the container running as PID 1 with no signal handling.
      # Boot's graceful shutdown needs the SIGTERM to arrive, which it does only because the
      # image uses an exec-form entrypoint; this is the matching half - ECS waits this long
      # before SIGKILL.
      stopTimeout = var.stop_timeout_seconds
    }
  ])

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.service_name}", Service = var.service_name })
}

# The stable internal name: <service>.<internal_domain>. Registered whether or not the service
# is behind the load balancer, because service-to-service calls use this and nothing else.
resource "aws_service_discovery_service" "this" {
  name = var.service_name

  dns_config {
    namespace_id = var.namespace_id

    dns_records {
      # A record with a short TTL, not SRV: the callers are Spring `RestClient` instances using
      # a plain host and port. Ten seconds so a redeployed task is reachable quickly - the JVM's
      # own DNS cache is the longer pole here, which is why the services set
      # networkaddress.cache.ttl rather than relying on this alone.
      type = "A"
      ttl  = 10
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    # ECS reports task health into Cloud Map itself. A Route 53 health check cannot reach a task
    # in a private subnet anyway, so the alternative would be a health check that always fails.
    failure_threshold = 1
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.service_name}" })
}

resource "aws_ecs_service" "this" {
  name            = var.service_name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  # On-demand for the broker and anything else that must not be reclaimed; Spot otherwise.
  # Expressed as a strategy rather than `launch_type` because the two are mutually exclusive and
  # setting both is a plan-time error that names neither.
  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = var.security_group_ids
    # Private subnets with no internet route: a public IP here would be assigned and unroutable.
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = var.service_name
      container_port   = var.container_port
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.this.arn
  }

  # How long ECS ignores load balancer health checks after a task starts. Only meaningful with
  # a load balancer attached, and it must exceed the application's start-up time or the target
  # group deregisters a task that is still migrating its schema.
  health_check_grace_period_seconds = var.target_group_arn == null ? null : var.health_check_grace_seconds

  deployment_circuit_breaker {
    # **The most important four lines in this module.** Without the circuit breaker, a
    # deployment whose tasks cannot start does not fail - it retries for ever, while the
    # previous version keeps serving. The deploy appears to hang, CI times out, and nothing says
    # the new image is broken. With rollback, ECS returns to the last working task definition
    # and marks the deployment failed, which is a signal CI can act on.
    enable   = true
    rollback = true
  }

  # 100/200 means: never drop below the desired count, and allow twice it briefly. On a single
  # task that is the difference between a rolling deploy and thirty seconds of 503s.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Lets `aws ecs execute-command` open a shell in a task. The task role holds no permissions,
  # so this is the only way to look inside one - and a service in a private subnet with no
  # bastion is otherwise unreachable by any means at all.
  enable_execute_command = var.enable_execute_command

  propagate_tags = "SERVICE"

  lifecycle {
    # CI deploys by registering a new task definition revision and updating the service. Without
    # this, the next `terraform apply` sees the running revision as drift and rolls the service
    # back to whatever image Terraform knows about - silently undoing a deployment.
    ignore_changes = [task_definition, desired_count]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.service_name}", Service = var.service_name })
}
