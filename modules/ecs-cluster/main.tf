/**
 * The ECS cluster, the two IAM roles every task needs, and the private DNS namespace services
 * find each other through.
 *
 * ## Two roles, and the difference is the whole security model
 *
 * - **Execution role** — used by the ECS *agent*, before the container starts: pull the image,
 *   fetch the secrets named in the task definition, create the log stream. The container never
 *   holds these credentials.
 * - **Task role** — assumed by the *application*. This is what an exploited service can use.
 *
 * They are separate so that a service which needs no AWS API at all - which is all six of these,
 * since they read their secrets as environment variables injected before start-up - gets a task
 * role with nothing attached. A remote-code-execution bug then yields an AWS identity that can
 * do nothing. Merging the two, which is the usual shortcut, would hand that same bug permission
 * to read every secret on the platform.
 */

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    # Per-service CPU and memory metrics. Off by default in ECS, and without it the only
    # question you cannot answer is the one that matters when a task is being killed: was it
    # memory, or was it the health check.
    name  = "containerInsights"
    value = var.container_insights ? "enhanced" : "disabled"
  }

  tags = merge(var.tags, { Name = var.name_prefix })
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = var.use_fargate_spot ? ["FARGATE", "FARGATE_SPOT"] : ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }
}

# ---------------------------------------------------------------------------
# Service discovery
# ---------------------------------------------------------------------------

# Cloud Map gives every service a stable name inside the VPC: the gateway calls
# http://users.martensa.internal:9001 and never learns a task's IP.
#
# **This is why the gateway needs no service registry.** Fargate tasks get a new private IP on
# every deployment, so a hard-coded address is correct until the first redeploy - at which point
# the gateway answers 503 for a service that is running perfectly.
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.internal_domain
  description = "Internal service discovery for ${var.name_prefix}"
  vpc         = var.vpc_id

  tags = merge(var.tags, { Name = var.internal_domain })
}

# ---------------------------------------------------------------------------
# Execution role - the agent's identity
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-execution"
  description        = "Used by the ECS agent to pull images, read secrets and write logs"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy above covers ECR and CloudWatch Logs but NOT Secrets Manager, and the
# failure mode is worth knowing: the task definition is accepted, the task starts, and it stops
# immediately with `ResourceInitializationError: unable to pull secrets`. Nothing in the
# application logs, because the application never ran.
#
# Scoped to this environment's secret prefix rather than `*`. The execution role is the one
# identity on the platform that can read secrets, so the blast radius of it leaking is exactly
# the set of secrets this statement names.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.name_prefix}/*",
    ]
  }

  # RDS-managed master credentials get an AWS-generated name that does not match the prefix
  # above, so they are named separately rather than by widening the wildcard.
  dynamic "statement" {
    for_each = length(var.additional_secret_arns) > 0 ? [1] : []

    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.additional_secret_arns
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# ---------------------------------------------------------------------------
# Task role - the application's identity
# ---------------------------------------------------------------------------

# Deliberately empty. None of the seven services calls an AWS API: secrets arrive as environment
# variables injected by the agent, logs go through the log driver, and nothing writes to S3.
#
# It exists anyway, rather than being omitted, so that ECS Exec can be attached to it for
# debugging and so the next service that *does* need an AWS permission has an obvious place to
# put it - rather than the permission being added to the execution role, where it would also be
# granted to every other task.
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-ecs-task"
  description        = "Assumed by the application containers. Intentionally holds no permissions."
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = var.tags
}
