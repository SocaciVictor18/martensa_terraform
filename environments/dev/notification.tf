/**
 * The notification service, and the first task on this platform that calls an AWS API.
 *
 * Everything else here is declared in `main.tf` alongside the other services. This one is in its
 * own file because it brings an IAM role with it, and a role among the service blocks would be
 * the least likely thing in this configuration to be noticed.
 *
 * ## Why it has its own task role
 *
 * `modules/ecs-cluster` creates one task role, shared by every service, and says of it:
 * *"Deliberately empty. None of the seven services calls an AWS API... It exists anyway so that
 * the next service that does need an AWS permission has an obvious place to put it - rather than
 * the permission being added to the execution role, where it would also be granted to every
 * other task."*
 *
 * This is that service, and the shared role turns out to be the wrong place after all - for the
 * same reason the execution role was. Attaching `ses:SendEmail` there would grant it to Cart and
 * to the storefront's gateway as well, and a permission held by six tasks that cannot use it is
 * a permission nobody will think to remove. So: a role per service, starting with the one that
 * needs something. The other six keep sharing the empty one, because they still need nothing.
 *
 * **REMOVE WHEN a second service needs an AWS permission** - at two, this belongs in
 * `modules/service` as an optional policy document, not copied into a second file here.
 */

# ---------------------------------------------------------------------------
# The task role: SES, and nothing else
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "notification_task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

/**
 * Send, and only send.
 *
 * `ses:SendEmail` covers the SESv2 `SendEmail` call this service makes. Not `ses:*`: that
 * includes `DeleteIdentity`, which would let a compromised task remove the domain verification
 * and take the platform's ability to send email with it - a failure that looks like SES being
 * broken and takes a DNS round trip to undo.
 *
 * ## Why the identity condition is here
 *
 * Without it, this role may send *as any verified identity in the account*. That matters more
 * than it sounds: SES identities are what a recipient's mail client shows as the sender, so an
 * unconstrained send permission is permission to send mail that appears to come from anyone the
 * account has verified. Scoping it to the configured from-address means the worst a compromised
 * task can do is send from the address it was already sending from.
 *
 * The resource is the identity ARN, which is how SES expresses "you may send as this". It is
 * built by hand rather than read from an `aws_ses_domain_identity` data source because the
 * identity is verified out of band - see the note on `notification_mail_domain` in variables.tf.
 */
data "aws_iam_policy_document" "notification_ses" {
  statement {
    effect = "Allow"
    actions = [
      "ses:SendEmail",
      # The SESv2 SDK's SendEmail maps to this action name as well, depending on whether a raw
      # MIME message is built. Both are the same capability - send one message - so granting one
      # without the other only produces an AccessDenied that names an action nobody configured.
      "ses:SendRawEmail",
    ]

    resources = [
      "arn:aws:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/${local.notification_mail_domain}",
    ]
  }
}

resource "aws_iam_role" "notification_task" {
  name               = "${local.name_prefix}-notification-task"
  description        = "The notification service's container. Holds SES send permission and nothing else."
  assume_role_policy = data.aws_iam_policy_document.notification_task_assume.json

  tags = { Name = "${local.name_prefix}-notification-task" }
}

resource "aws_iam_role_policy" "notification_ses" {
  name   = "ses-send"
  role   = aws_iam_role.notification_task.id
  policy = data.aws_iam_policy_document.notification_ses.json
}

# ---------------------------------------------------------------------------
# The service
# ---------------------------------------------------------------------------

locals {
  # The domain SES sends as, derived from the from-address so the two cannot disagree. A policy
  # scoped to one domain and a MAIL_FROM on another produces AccessDenied at the moment of the
  # first send - which is inside a scheduled tick, so the symptom is a queue that stops draining
  # rather than a request that fails.
  notification_mail_domain = split("@", var.notification_mail_from)[1]
}

module "notification" {
  source = "../../modules/service"

  name_prefix        = local.name_prefix
  service_name       = "notification"
  region             = var.region
  cluster_id         = module.ecs.cluster_id
  namespace_id       = module.ecs.namespace_id
  internal_domain    = module.ecs.internal_domain
  execution_role_arn = module.ecs.execution_role_arn
  task_role_arn      = aws_iam_role.notification_task.arn
  subnet_ids         = module.network.private_subnet_ids
  security_group_ids = [module.network.service_security_group_id]
  image              = var.images["notification"]
  container_port     = local.service_ports.notification
  desired_count      = lookup(var.desired_counts, "notification", 1)
  capacity_provider  = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"

  environment = merge(local.common_environment, {
    # Both looked up at the moment of sending rather than carried on the events - the addresses
    # and product names this service renders are delivery channels and labels, where the current
    # value is the right one. See the service's docs 3 and 6c.
    USERS_BASE_URL   = module.users.base_url
    CATALOG_BASE_URL = module.catalog.base_url

    MAIL_FROM      = var.notification_mail_from
    MAIL_FROM_NAME = var.notification_mail_from_name
    MAIL_REPLY_TO  = var.notification_mail_reply_to

    # Where the low-stock alert goes. Distinct from MAIL_FROM: one is what recipients see in the
    # From line, the other is a human's inbox. Unset, the alert is queued and then abandoned
    # with a log line, which is the correct answer to "nobody asked for these" - see
    # NotificationQueue.queueForOperations.
    ADMIN_ALERT_EMAIL = var.notification_admin_alerts

    # Every link in every message. The storefront's public origin, not the API's: a customer
    # clicking "Înapoi la magazin" must land on the shop.
    STOREFRONT_BASE_URL = length(var.storefront_domains) > 0 ? "https://${var.storefront_domains[0]}" : "https://${module.frontend.domain_name}"

    # **Not optional, and the reason is worth the line.** In the `aws` profile the transport is
    # SesMailSender, whose SesV2Client resolves its region at construction from the credential
    # chain. ECS does supply AWS_REGION to every task, so this is belt and braces - but the CI
    # smoke test had to set it explicitly after the container built cleanly and never became
    # ready, with "Unable to load region from any of the providers in the chain" as the only
    # clue. Stating it here means the same failure cannot come back through a runtime change.
    AWS_REGION = var.region
  })

  secrets = {
    DB_URL         = "${module.database.service_secret_arns["notification"]}:url::"
    DB_USERNAME    = "${module.database.service_secret_arns["notification"]}:username::"
    DB_PASSWORD    = "${module.database.service_secret_arns["notification"]}:password::"
    JWT_PUBLIC_KEY = local.jwt_public_key_secret

    # The same secret twice, under the two names this service reads it as: one for the token it
    # presents to Users, one for Catalog. Two variables rather than one because the service does
    # not assume the two callees share a secret - which they need not, and will not once each
    # service has its own identity.
    USERS_INTERNAL_TOKEN   = local.internal_api_token_secret
    CATALOG_INTERNAL_TOKEN = local.internal_api_token_secret
  }
}
