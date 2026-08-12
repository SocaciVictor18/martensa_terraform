/**
 * Apache Kafka in KRaft mode, as a single Fargate task, with EFS for its log directories.
 *
 * ## Why this rather than MSK
 *
 * MSK Serverless is the AWS-native answer and it is billed per cluster-hour whether or not
 * anything is published - roughly $540 a month for a platform that is not serving customers.
 * This is about $15 and can be taken to zero by setting `desired_count = 0`, which is what an
 * environment that is used a few evenings a week should cost.
 *
 * The security argument runs the same way. The broker sits in a private subnet with no public
 * IP and a security group that admits only the application tasks; there is no path to it from
 * outside the VPC, so there is nothing to authenticate from outside and no credential to leak.
 * MSK's IAM auth is genuinely better *authentication*, but it is protecting a surface this
 * design does not expose. The rejected third option - Confluent's free tier - is the one that
 * would have put a bootstrap address and an API key on the public internet.
 *
 * **What is given up, plainly: one broker, no replication.** A partition has a single copy. If
 * the task is replaced, the topics survive only because EFS holds the log directories; if EFS
 * were removed, every topic and every consumer offset would be recreated empty and the platform
 * would look fine while silently having lost every unconsumed event. This is not a production
 * broker and the module does not pretend otherwise.
 *
 * ## The advertised listener is the thing that breaks
 *
 * A Kafka client connects to the bootstrap address, asks for metadata, and is then told where
 * the brokers actually are - the *advertised* listeners. If a broker advertises its container's
 * private IP, every producer connects to bootstrap successfully and then fails on the next
 * call, because that IP changes on every task replacement. If it advertises `localhost`, which
 * is the default when nothing is set, clients are redirected to themselves.
 *
 * The symptom in both cases is the one that wastes an afternoon: the connection succeeds,
 * metadata is fetched, and every `send()` times out with `TimeoutException: Topic not present
 * in metadata` - which reads like a missing topic rather than a routing problem. The fix is to
 * advertise the Cloud Map name, which is stable across task replacements.
 */

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

resource "aws_efs_file_system" "kafka" {
  creation_token = "${var.name_prefix}-kafka"
  encrypted      = true

  # Bursting, not Elastic. Elastic throughput is billed per GB read and written, which for a
  # broker writing every event twice - log and index - is the mode that produces a surprising
  # bill. Bursting gives baseline throughput proportional to size plus a credit balance, and a
  # broker at this volume never leaves the baseline.
  throughput_mode = "bursting"

  lifecycle_policy {
    # Kafka reads recent segments and never touches old ones again. Moving them to infrequent
    # access after a month cuts the storage cost by roughly 90% for data that is retained only
    # because the retention policy has not expired it yet.
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-kafka-efs"
  description = "NFS from the broker task only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka-efs" })
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_broker" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the Kafka task"
  referenced_security_group_id = aws_security_group.broker.id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

# One mount target per subnet. A task placed in a subnet with no mount target cannot mount the
# filesystem at all, and ECS reports it as a generic `ResourceInitializationError` that names
# EFS but not the subnet.
resource "aws_efs_mount_target" "kafka" {
  count = length(var.subnet_ids)

  file_system_id  = aws_efs_file_system.kafka.id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# An access point rather than mounting the root. It pins the uid/gid and the sub-path, so the
# container writes as the user Kafka runs as (1001 in the Bitnami image) without the task
# needing root, and a second workload sharing this filesystem cannot read the broker's data.
resource "aws_efs_access_point" "kafka" {
  file_system_id = aws_efs_file_system.kafka.id

  posix_user {
    uid = 1001
    gid = 1001
  }

  root_directory {
    path = "/kafka"

    creation_info {
      owner_uid   = 1001
      owner_gid   = 1001
      permissions = "0755"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_security_group" "broker" {
  name        = "${var.name_prefix}-kafka"
  description = "The Kafka broker. Reachable from the application tasks only."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

resource "aws_vpc_security_group_ingress_rule" "broker_from_services" {
  security_group_id            = aws_security_group.broker.id
  description                  = "Kafka clients: the six services"
  referenced_security_group_id = var.service_security_group_id
  from_port                    = 9092
  to_port                      = 9092
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "broker_all" {
  security_group_id = aws_security_group.broker.id
  description       = "EFS and the VPC endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_service_discovery_service" "kafka" {
  name = "kafka"

  dns_config {
    namespace_id = var.namespace_id

    dns_records {
      type = "A"
      ttl  = 10
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

# ---------------------------------------------------------------------------
# The broker
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "kafka" {
  name              = "/ecs/${var.name_prefix}/kafka"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

locals {
  # What clients are told to connect to. Stable across task replacements, which is the whole
  # point - see the module header.
  advertised_host = "kafka.${var.internal_domain}"
}

resource "aws_ecs_task_definition" "kafka" {
  family                   = "${var.name_prefix}-kafka"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  volume {
    name = "kafka-data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.kafka.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.kafka.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "kafka"
      image     = var.image
      essential = true

      portMappings = [
        { containerPort = 9092, protocol = "tcp", name = "kafka" }
      ]

      mountPoints = [
        { sourceVolume = "kafka-data", containerPath = "/bitnami/kafka", readOnly = false }
      ]

      environment = [
        # KRaft: no ZooKeeper. The same mode the local Docker Compose broker and Testcontainers
        # run, so there is exactly one broker technology in the project - a ZooKeeper cluster
        # here would mean the thing that is tested and the thing that runs are different.
        { name = "KAFKA_CFG_PROCESS_ROLES", value = "broker,controller" },
        { name = "KAFKA_CFG_NODE_ID", value = "1" },
        { name = "KAFKA_CFG_CONTROLLER_QUORUM_VOTERS", value = "1@localhost:9093" },
        { name = "KAFKA_CFG_LISTENERS", value = "PLAINTEXT://:9092,CONTROLLER://:9093" },
        { name = "KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP", value = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT" },
        { name = "KAFKA_CFG_CONTROLLER_LISTENER_NAMES", value = "CONTROLLER" },
        { name = "KAFKA_CFG_INTER_BROKER_LISTENER_NAME", value = "PLAINTEXT" },

        # The line the module header is about. Anything else here - localhost, the container's
        # own IP - produces a broker that accepts a connection and then cannot be published to.
        { name = "KAFKA_CFG_ADVERTISED_LISTENERS", value = "PLAINTEXT://${local.advertised_host}:9092" },

        # PLAINTEXT, and the justification is the same as Redis having no auth token: the broker
        # is in a private subnet with no internet route, and its security group admits only the
        # six service tasks. If either of those changes, this needs SASL and TLS before the
        # change lands.

        # One broker means one replica is all that can exist. Left at the default of 3, every
        # topic creation fails with INVALID_REPLICATION_FACTOR - including the internal
        # `__consumer_offsets` topic, which fails at start-up and takes the broker with it.
        { name = "KAFKA_CFG_DEFAULT_REPLICATION_FACTOR", value = "1" },
        { name = "KAFKA_CFG_OFFSETS_TOPIC_REPLICATION_FACTOR", value = "1" },
        { name = "KAFKA_CFG_TRANSACTION_STATE_LOG_REPLICATION_FACTOR", value = "1" },
        { name = "KAFKA_CFG_TRANSACTION_STATE_LOG_MIN_ISR", value = "1" },

        # OFF. Every producer on this platform declares its topics as NewTopic beans, and the
        # blueprint requires it: an auto-created topic appears on first send, after which an
        # already-subscribed consumer waits for its metadata refresh - five minutes by default -
        # and the symptom is a working producer that looks broken. Auto-creation would also let
        # a consumer that started first fix the partition count at one.
        { name = "KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE", value = "false" },

        { name = "KAFKA_CFG_LOG_RETENTION_HOURS", value = tostring(var.retention_hours) },
        { name = "KAFKA_HEAP_OPTS", value = "-Xmx${var.heap_mb}m -Xms${var.heap_mb}m" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.kafka.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }

      healthCheck = {
        # Asks the broker to list topics over its own protocol. A TCP check would pass while the
        # broker was still replaying its log directory and rejecting every request.
        command     = ["CMD-SHELL", "kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1 || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 120
      }

      # Kafka flushes and closes its log segments on SIGTERM. Cut short, the next start replays
      # the log and can find a partially written segment, which it truncates - losing the events
      # in it.
      stopTimeout = 60
    }
  ])

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}

resource "aws_ecs_service" "kafka" {
  name            = "kafka"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.kafka.arn
  desired_count   = var.desired_count

  # **FARGATE, never FARGATE_SPOT.** Spot can reclaim a task with two minutes' notice, and every
  # reclaim is a broker restart: producers retry, consumers rebalance, and any segment not
  # flushed is replayed. The services tolerate that individually - they are idempotent by
  # contract - but a broker that disappears several times a day is an outage with extra steps.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.broker.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kafka.arn
  }

  # 0/100, the opposite of the application services. Two brokers must never run at once: they
  # would share node id 1 and the same EFS log directory, and the second refuses to start with a
  # lock error - or worse, starts and corrupts the log. So the old task stops before the new one
  # begins, which costs a short outage on every deployment and is the correct trade for a
  # single-broker design.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = var.enable_execute_command

  # Mount targets must exist before a task tries to mount the filesystem. Terraform cannot infer
  # this - the task definition references the file system, not the mount targets - so without it
  # the first apply races and the broker fails to start on a filesystem that is "created".
  depends_on = [aws_efs_mount_target.kafka]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kafka" })
}
