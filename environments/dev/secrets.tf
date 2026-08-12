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
