/**
 * ElastiCache for Redis: the Cart service's entire datastore.
 *
 * **Cart owns no tables, and that is deliberate** - a basket is short-lived, read constantly and
 * worth nothing an hour after the customer leaves. What follows from that is the setting most
 * people get backwards here: this cache has **no backups and no failover**, and losing it loses
 * every open basket and nothing else. Paying for Multi-AZ on a basket store is paying for
 * durability on data whose defining property is that it does not need any.
 *
 * If a basket ever becomes something a customer expects to find next week, this is the module
 * that changes - not by adding snapshots to a cache, but by moving the basket to Postgres.
 */

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.name_prefix}-redis"
  description = "Private subnets only"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis, from the Cart task only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_vpc_security_group_ingress_rule" "from_services" {
  security_group_id            = aws_security_group.redis.id
  description                  = "Redis from the application tasks"
  referenced_security_group_id = var.service_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Cart baskets for ${var.name_prefix}"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # One node. See the header: a basket store does not need a standby, and the second node
  # doubles the cost of the cheapest component on the platform.
  num_cache_clusters         = var.node_count
  automatic_failover_enabled = var.node_count > 1
  multi_az_enabled           = var.node_count > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  # In transit but not at rest. In transit matters: the basket carries product ids and
  # quantities across the VPC, and `REDIS_SSL_ENABLED` in Cart's aws profile exists for this.
  # At rest would encrypt data that is deleted within the hour and would rule out the cheapest
  # node types, which is a cost for no threat this store actually faces.
  transit_encryption_enabled = true

  # No auth token. Justified only because the security group admits one source and the subnet
  # has no internet route - if either of those changes, this needs a token from Secrets Manager
  # before the change lands.
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # Explicitly zero. ElastiCache defaults to keeping a daily snapshot on some node types, and
  # snapshots of a basket cache are storage billed for data nobody will ever restore.
  snapshot_retention_limit = 0

  maintenance_window = "sun:03:30-sun:04:30"
  apply_immediately  = var.apply_immediately

  auto_minor_version_upgrade = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })
}

resource "aws_elasticache_parameter_group" "this" {
  name        = "${var.name_prefix}-redis"
  family      = var.parameter_group_family
  description = "Cart basket cache"

  # Evict the least recently used key with a TTL when memory runs out, rather than the default
  # `noeviction` - which stops accepting writes and turns "the cache is full" into "nobody can
  # add anything to a basket", with an OOM error from Redis that surfaces in Cart as a 500.
  #
  # volatile-lru rather than allkeys-lru: Cart sets a TTL on every basket key, so the two behave
  # identically today, and volatile-lru refuses to evict a key that was written without one -
  # which is the correct alarm if something ever stores state here that was meant to persist.
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}
