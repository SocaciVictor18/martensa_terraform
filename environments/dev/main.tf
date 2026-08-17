/**
 * The dev environment: everything wired together.
 *
 * Read top to bottom, this is the dependency order - network, then the stores, then the
 * cluster, then the seven services. The only part that is not obvious is why the gateway is
 * declared after the six services: it needs their base URLs, and Terraform resolves that from
 * the module outputs rather than from the order of the blocks.
 */

locals {
  name_prefix = "martensa-${var.environment}"

  # Ports come from the allocation table in martensa-platform-parent/docs/infrastructure.md.
  # They are the same locally and on AWS on purpose: a port that differs between environments is
  # one more thing to be wrong in a runbook at three in the morning.
  service_ports = {
    users        = 9001
    catalog      = 9002
    inventory    = 9003
    cart         = 9004
    orders       = 9005
    payments     = 9006
    notification = 9007
  }

  gateway_port = 9000

  # The storefront's origin, which is what the services must accept CORS from. The API's own
  # host is not in this list: a service does not make cross-origin requests to itself.
  cors_origins = join(",", length(var.storefront_domains) > 0
    ? [for domain in var.storefront_domains : "https://${domain}"]
    : ["https://${module.frontend.domain_name}"]
  )
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  name_prefix             = local.name_prefix
  region                  = var.region
  availability_zone_count = var.availability_zone_count
  gateway_port            = local.gateway_port
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix
  services    = concat(keys(local.service_ports), ["gateway"])
}

# ---------------------------------------------------------------------------
# Stores
# ---------------------------------------------------------------------------

module "database" {
  source = "../../modules/database"

  name_prefix               = local.name_prefix
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.private_subnet_ids
  service_security_group_id = module.network.service_security_group_id

  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot
}

module "redis" {
  source = "../../modules/redis"

  name_prefix               = local.name_prefix
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.private_subnet_ids
  service_security_group_id = module.network.service_security_group_id
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

module "ecs" {
  source = "../../modules/ecs-cluster"

  name_prefix      = local.name_prefix
  region           = var.region
  account_id       = data.aws_caller_identity.current.account_id
  vpc_id           = module.network.vpc_id
  use_fargate_spot = var.use_fargate_spot

  # The RDS-managed master credential gets an AWS-generated name outside the prefix, so the
  # execution role would not be able to read it under the scoped policy alone.
  additional_secret_arns = [module.database.master_secret_arn]
}

module "kafka" {
  source = "../../modules/kafka"

  name_prefix               = local.name_prefix
  region                    = var.region
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.private_subnet_ids
  service_security_group_id = module.network.service_security_group_id
  cluster_id                = module.ecs.cluster_id
  namespace_id              = module.ecs.namespace_id
  internal_domain           = module.ecs.internal_domain
  execution_role_arn        = module.ecs.execution_role_arn
  task_role_arn             = module.ecs.task_role_arn
}

# ---------------------------------------------------------------------------
# The six services
# ---------------------------------------------------------------------------

locals {
  # Every service gets these. Kept in one place so a broker address change is one edit rather
  # than six, and so no service can quietly be missing one.
  common_environment = {
    KAFKA_BOOTSTRAP_SERVERS = module.kafka.bootstrap_servers
    CORS_ALLOWED_ORIGINS    = local.cors_origins
  }

  # The public key is not a secret - it exists to be distributed - but it is stored in Secrets
  # Manager anyway so that regenerating the keypair is one write instead of seven redeployments.
  jwt_public_key_secret = aws_secretsmanager_secret.application["jwt/public-key"].arn

  # One shared secret, three services, three different environment variable names. Users and
  # Catalog read it as the token they *expect* on /api/internal/**; the notification service
  # reads it twice as the token it *presents*. One value rather than a pair per direction,
  # because a rotation that has to land in three task definitions at the same instant is hard
  # enough without also being three different values - and the failure it causes is 401s that
  # read as the callee being broken.
  #
  # **REMOVE WHEN the platform has real service identity** (blueprint 6). A shared bearer secret
  # with no expiry and no way to tell one caller from another is the placeholder, not the plan.
  internal_api_token_secret = aws_secretsmanager_secret.internal_api_token.arn
}

module "users" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "users"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["users"]
  container_port     = local.service_ports.users
  desired_count      = lookup(var.desired_counts, "users", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = merge(local.common_environment, {
    GOOGLE_CLIENT_ID        = var.google_client_id
    BOOTSTRAP_ADMIN_USER_ID = var.bootstrap_admin_user_id
    # Secure, and SameSite=None because the storefront is on a different origin from the API -
    # cloudfront.net and the API domain are not the same site. Lax would mean the browser
    # withholds the refresh cookie on the storefront's own refresh call, and the customer is
    # signed out every time their access token expires.
    REFRESH_COOKIE_SECURE    = "true"
    REFRESH_COOKIE_SAME_SITE = "None"
  })

  secrets = {
    DB_URL          = "${module.database.service_secret_arns["users"]}:url::"
    DB_USERNAME     = "${module.database.service_secret_arns["users"]}:username::"
    DB_PASSWORD     = "${module.database.service_secret_arns["users"]}:password::"
    JWT_PRIVATE_KEY = aws_secretsmanager_secret.application["jwt/private-key"].arn
    JWT_PUBLIC_KEY  = local.jwt_public_key_secret
    # What Users requires on /api/internal/contacts. Unset, that endpoint fails closed and the
    # notification service gets 401 on every lookup - so no customer receives any email at all,
    # while Users itself looks perfectly healthy. Users logs a warning naming this property at
    # start-up precisely because the symptom points at the wrong service.
    INTERNAL_API_TOKEN = local.internal_api_token_secret
  }
}

module "catalog" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "catalog"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["catalog"]
  container_port     = local.service_ports.catalog
  desired_count      = lookup(var.desired_counts, "catalog", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = local.common_environment

  secrets = {
    DB_URL         = "${module.database.service_secret_arns["catalog"]}:url::"
    DB_USERNAME    = "${module.database.service_secret_arns["catalog"]}:username::"
    DB_PASSWORD    = "${module.database.service_secret_arns["catalog"]}:password::"
    JWT_PUBLIC_KEY = local.jwt_public_key_secret
    # What Catalog requires on /api/internal/products. Unset, low-stock alerts still reach
    # operations but name products by a raw id - which is the failure mode this whole platform
    # prefers, and is also the one nobody reports as a bug.
    INTERNAL_API_TOKEN = local.internal_api_token_secret
  }
}

module "inventory" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "inventory"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["inventory"]
  container_port     = local.service_ports.inventory
  desired_count      = lookup(var.desired_counts, "inventory", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = local.common_environment

  secrets = {
    DB_URL         = "${module.database.service_secret_arns["inventory"]}:url::"
    DB_USERNAME    = "${module.database.service_secret_arns["inventory"]}:username::"
    DB_PASSWORD    = "${module.database.service_secret_arns["inventory"]}:password::"
    JWT_PUBLIC_KEY = local.jwt_public_key_secret
  }
}

# Cart is the one service with no database. It owns a Redis keyspace and nothing else, which is
# why there is no `cart` entry in the database module's service_databases.
module "cart" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "cart"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["cart"]
  container_port     = local.service_ports.cart
  desired_count      = lookup(var.desired_counts, "cart", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = merge(local.common_environment, {
    REDIS_HOST = module.redis.host
    REDIS_PORT = tostring(module.redis.port)
    # Matches transit_encryption_enabled on the replication group. A client that connects
    # without TLS to a cache that requires it fails at the handshake, and Lettuce reports it as
    # a connection reset - which reads like a network fault rather than a protocol mismatch.
    REDIS_SSL_ENABLED = "true"
    CATALOG_BASE_URL  = module.catalog.base_url
  })

  secrets = {
    JWT_PUBLIC_KEY = local.jwt_public_key_secret
  }
}

module "orders" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "orders"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["orders"]
  container_port     = local.service_ports.orders
  desired_count      = lookup(var.desired_counts, "orders", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = merge(local.common_environment, {
    CART_BASE_URL      = module.cart.base_url
    CATALOG_BASE_URL   = module.catalog.base_url
    INVENTORY_BASE_URL = module.inventory.base_url
    # Orders calls Users to hold a loyalty voucher during checkout. Only reached when the
    # customer attached a code, which is what makes this the kind of variable that gets
    # forgotten: the service starts fine without it and every checkout without a voucher works,
    # so the first failure is a customer using a voucher on a deployed environment.
    USERS_BASE_URL = module.users.base_url
  })

  secrets = {
    DB_URL         = "${module.database.service_secret_arns["orders"]}:url::"
    DB_USERNAME    = "${module.database.service_secret_arns["orders"]}:username::"
    DB_PASSWORD    = "${module.database.service_secret_arns["orders"]}:password::"
    JWT_PUBLIC_KEY = local.jwt_public_key_secret
  }
}

module "payments" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "payments"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["payments"]
  container_port     = local.service_ports.payments
  desired_count      = lookup(var.desired_counts, "payments", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = local.common_environment

  secrets = {
    DB_URL                = "${module.database.service_secret_arns["payments"]}:url::"
    DB_USERNAME           = "${module.database.service_secret_arns["payments"]}:username::"
    DB_PASSWORD           = "${module.database.service_secret_arns["payments"]}:password::"
    JWT_PUBLIC_KEY        = local.jwt_public_key_secret
    EUPLATESC_MERCHANT_ID = aws_secretsmanager_secret.application["euplatesc/merchant-id"].arn
    EUPLATESC_SECRET_KEY  = aws_secretsmanager_secret.application["euplatesc/secret-key"].arn
  }
}

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------

module "alb" {
  source = "../../modules/alb"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  security_group_id   = module.network.alb_security_group_id
  gateway_port        = local.gateway_port
  certificate_arn     = var.api_certificate_arn
  deletion_protection = var.alb_deletion_protection
}

# The gateway is the only service behind the load balancer, and the only one in its own security
# group. It owns no data; everything it does is route, authenticate and forward.
module "gateway" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "gateway"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = module.ecs.task_role_arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.gateway_security_group_id]
  image              = var.images["gateway"]
  container_port     = local.gateway_port
  desired_count      = lookup(var.desired_counts, "gateway", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
  target_group_arn   = module.alb.target_group_arn

  environment = {
    CORS_ALLOWED_ORIGINS = local.cors_origins
    USERS_BASE_URL       = module.users.base_url
    CATALOG_BASE_URL     = module.catalog.base_url
    INVENTORY_BASE_URL   = module.inventory.base_url
    CART_BASE_URL        = module.cart.base_url
    ORDERS_BASE_URL      = module.orders.base_url
    PAYMENTS_BASE_URL    = module.payments.base_url
  }

  secrets = {
    JWT_PUBLIC_KEY = local.jwt_public_key_secret
  }
}

# ---------------------------------------------------------------------------
# Storefront
# ---------------------------------------------------------------------------

module "frontend" {
  source = "../../modules/frontend"

  name_prefix     = local.name_prefix
  bucket_name     = var.storefront_bucket_name
  domain_names    = var.storefront_domains
  certificate_arn = var.storefront_certificate_arn
}
