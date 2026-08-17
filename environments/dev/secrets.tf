/**
 * Application secrets that Terraform creates but does not know the value of.
 *
 * ## Why the values are not here
 *
 * A value written in Terraform ends up in the state file in plain text, in every historical
 * version the bucket keeps, and in the plan output of anyone who runs `terraform plan`. For the
 * per-service database passwords that is an accepted trade - they are generated, scoped to one
 * database, and managing six of them by hand is worse. For these it is not:
 *
 * - **The JWT signing key** mints tokens for every account on the platform, including
 *   administrators. Whoever holds it is every customer.
 * - **The EuPlătesc merchant key** signs payment requests and verifies the notifications that
 *   settle orders. Whoever holds it can forge a settled payment.
 *
 * So Terraform creates the secret and `ignore_changes` keeps it from ever touching the value.
 * The value is put in once, out of band, with `aws secretsmanager put-secret-value`. Rotating
 * it is the same command; Terraform neither knows nor cares.
 *
 * **The empty placeholder is deliberate and it is a trap worth naming.** A secret with no
 * version cannot be referenced by a task definition at all - ECS fails the task with
 * `ResourceInitializationError` before the container starts, and the message names the secret
 * but not the fact that it is empty. Creating an obvious placeholder means the failure is a
 * service that starts and rejects every token, which is far easier to diagnose than a task that
 * never runs.
 */

locals {
  # One entry per secret this platform needs a human to fill in.
  application_secrets = {
    "jwt/private-key"       = "RSA private key, PEM. Generate with: openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048"
    "jwt/public-key"        = "The public half of the above. Every service and the gateway verify with it; all seven must match."
    "euplatesc/merchant-id" = "EuPlatesc merchant id."
    "euplatesc/secret-key"  = "EuPlatesc merchant key, hex. Signs the payment form and verifies the IPN."
  }
}

resource "aws_secretsmanager_secret" "application" {
  for_each = local.application_secrets

  name        = "${local.name_prefix}/${each.key}"
  description = each.value

  # Zero so a destroy/apply cycle works in a scratch environment. Secrets Manager otherwise
  # keeps a deleted secret for 7-30 days and refuses to reuse the name, turning a rebuild into a
  # week's wait or a rename. Raise this for anything long-lived.
  recovery_window_in_days = 0

  tags = { Name = "${local.name_prefix}-${replace(each.key, "/", "-")}" }
}

resource "aws_secretsmanager_secret_version" "application_placeholder" {
  for_each = local.application_secrets

  secret_id = aws_secretsmanager_secret.application[each.key].id

  # Not the empty string: a value that says what it is, so a service failing with it in hand
  # produces a diagnosable error rather than a null-pointer somewhere in a PEM parser.
  secret_string = "REPLACE-ME"

  lifecycle {
    # The line that makes this work. Without it, every `terraform apply` would overwrite the
    # real key with the placeholder - and the symptom would be the whole platform rejecting
    # every token immediately after an unrelated infrastructure change.
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# The internal API token - generated, not hand-filled, and the reasoning is the point
# ---------------------------------------------------------------------------

/**
 * The shared secret that opens `/api/internal/**` on Users and Catalog.
 *
 * ## Why this one is generated when the four above are not
 *
 * The rule this repository follows is that Terraform never writes a secret value, because
 * anything it generates lands in state in plain text. This is the deliberate exception, and it
 * sits in the same tier as the per-service database passwords for the same reason: the state
 * bucket is encrypted, versioned and blocked from public access precisely so that this tier can
 * exist.
 *
 * What forces it here is the failure mode of the alternative. A hand-filled secret starts life
 * as `REPLACE-ME`, and for the JWT key that is loud - the platform rejects every token until
 * somebody fixes it, within minutes of the first request. **This one would be silent.** All
 * three services read the same value, so `REPLACE-ME` on every side *matches*: Users accepts it,
 * Catalog accepts it, the notification service presents it, and the platform works perfectly
 * with a credential that is written in this file, in git history, and identical in every
 * environment anyone copied it into. Nothing fails, so nobody looks.
 *
 * A secret whose insecure state is also its working state does not get replaced. Generating it
 * means the working state is the secure one, which is the only arrangement that survives
 * somebody being busy.
 *
 * ## What it opens, so the trade is stated rather than implied
 *
 * Users' half is the contact directory: every customer's name and email address, readable over
 * plain HTTP by anything inside the VPC that holds this string. That is why it is 48 characters
 * of generated entropy rather than something memorable, and why the endpoints fail closed when
 * it is unset rather than defaulting to open.
 *
 * **REMOVE WHEN the platform has real service identity** (blueprint 6). A bearer credential with
 * no expiry, no rotation story and no way to tell one caller from another is the placeholder,
 * not the plan. Rotating it today means changing this value and redeploying three services close
 * enough together that the gap is short - during which contact lookups 401 and email queues
 * rather than being lost, which is the one saving grace of the design.
 */
resource "random_password" "internal_api_token" {
  length = 48
  # No punctuation. The value travels in an HTTP header and is compared byte for byte; special
  # characters buy entropy that length gives more cheaply, and cost a class of bug where a shell
  # or a YAML file eats one of them and the mismatch reads as the callee being broken.
  special = false
}

resource "aws_secretsmanager_secret" "internal_api_token" {
  name        = "${local.name_prefix}/internal/api-token"
  description = "Shared secret for /api/internal/**. Users and Catalog expect it; the notification service presents it."

  recovery_window_in_days = 0

  tags = { Name = "${local.name_prefix}-internal-api-token" }
}

resource "aws_secretsmanager_secret_version" "internal_api_token" {
  secret_id     = aws_secretsmanager_secret.internal_api_token.id
  secret_string = random_password.internal_api_token.result

  # Deliberately NOT ignore_changes, unlike the four hand-filled secrets above. There the
  # lifecycle rule protects a real value from being overwritten by a placeholder; here Terraform
  # owns the value, so ignoring changes would mean a rotation performed out of band silently
  # disagrees with state and the next apply cannot put it back.
}
