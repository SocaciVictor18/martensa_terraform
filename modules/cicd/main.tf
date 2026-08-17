/**
 * The role GitHub Actions assumes to deploy, and the trust policy that is the whole point.
 *
 * ## Why this exists before there is a deploy workflow
 *
 * The alternative is an access key pair in GitHub's secrets, and it is worse in a way that is easy
 * to underrate: a long-lived credential with permission to replace what runs in production, held
 * by a system this repository does not control, with no expiry and no record of what used it. OIDC
 * replaces it with a token minted per workflow run, valid for that run, tied to a specific
 * repository and branch.
 *
 * Writing it now rather than with the workflow is deliberate. The workflow cannot be tested without
 * an applied environment; this can be reviewed, and the review is the part that matters, because
 * the failure mode below is silent.
 *
 * ## The condition on `sub` is the security boundary, not a filter
 *
 * The OIDC provider trusts *GitHub*, not this account's repositories. Without a `sub` condition,
 * **any repository on GitHub - anyone's - can mint a token this role accepts** and deploy to this
 * account. That is the classic misconfiguration of this pattern and it is invisible: the role
 * works perfectly for the intended workflow, so nothing fails and nothing is logged that looks
 * wrong.
 *
 * `StringLike` rather than `StringEquals` only because the branch is a variable and a pattern is
 * needed for the environment case; the owner and repository are always literal, so the wildcard
 * can never widen past repositories this owner controls.
 *
 * The `aud` condition is the second half. Without it a token minted for a different audience -
 * another AWS account, or another service that also trusts GitHub's issuer - would be accepted
 * here.
 */

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # One entry per repository allowed to deploy, each pinned to one branch. A repository absent
    # from this list cannot assume the role however many secrets it holds.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for repository in var.repositories :
        "repo:${var.github_owner}/${repository}:ref:refs/heads/${var.deploy_branch}"
      ]
    }
  }
}

/**
 * The provider itself.
 *
 * `thumbprint_list` is deliberately not set. AWS has validated GitHub's OIDC certificates against
 * its own trust store since mid-2023, so a hand-maintained thumbprint is no longer what secures
 * this - and a stale one used to break every deployment on the day GitHub rotated a certificate,
 * with an error that named a TLS failure rather than a configuration file. The provider computes
 * the attribute; pinning it would reintroduce exactly that maintenance.
 *
 * One per account, not one per environment. A second environment reuses this by importing it -
 * creating a second raises `EntityAlreadyExists`, which is the right error but arrives during an
 * apply rather than a plan.
 */
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-github-oidc" })
}

resource "aws_iam_role" "deploy" {
  name        = "${var.name_prefix}-github-deploy"
  description = "Assumed by GitHub Actions to push images and update ECS services. No console login."

  assume_role_policy = data.aws_iam_policy_document.github_assume.json

  # An hour. A deploy that takes longer than this has something wrong with it, and the credential
  # should not outlive the job that was issued it.
  max_session_duration = 3600

  tags = merge(var.tags, { Name = "${var.name_prefix}-github-deploy" })
}

# ---------------------------------------------------------------------------
# What it may do, and nothing else
# ---------------------------------------------------------------------------

/**
 * Push images, and read the ones already there.
 *
 * `GetAuthorizationToken` has to be on `*` - it is an account-level call and takes no resource -
 * which is why every other action here is scoped to the repositories this platform owns. Without
 * that scoping, permission to log in to ECR would be permission to overwrite any image in the
 * account.
 */
data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      # Reading tags is what lets a workflow refuse to overwrite an existing immutable tag with a
      # readable message rather than an API error.
      "ecr:DescribeImages",
    ]
    resources = var.ecr_repository_arns
  }

  /**
   * Register a new task definition and point the service at it. That is the whole deployment.
   *
   * `RegisterTaskDefinition` cannot be scoped to a resource - the thing it creates does not exist
   * yet - so the constraint that matters is `PassRole` below. `UpdateService` and the rest are
   * scoped to this cluster, so a compromised workflow cannot redeploy something else in the
   * account.
   */
  statement {
    sid       = "EcsRegisterTaskDefinition"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
      # What a workflow polls to know whether the deployment settled or the circuit breaker rolled
      # it back. Without it the workflow reports success the moment the API accepts the update,
      # which is before anything has actually started.
      "ecs:DescribeTasks",
      "ecs:ListTasks",
    ]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  /**
   * <strong>The statement that decides whether this role is safe.</strong>
   *
   * A task definition names the roles its container runs with. Permission to register one plus
   * unrestricted `iam:PassRole` is permission to run a container as **any role in the account** -
   * including an administrator - which turns a compromised workflow into a full account takeover
   * through a path that looks like an ordinary deployment.
   *
   * Scoped to exactly the roles this platform's tasks already use. Adding a service with its own
   * task role means adding it here, and the failure if it is forgotten is an explicit
   * AccessDenied naming the role - which is the right way round.
   */
  statement {
    sid       = "PassOnlyThePlatformsOwnTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = var.passable_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  /**
   * The storefront: upload the bundle, then invalidate the edge caches.
   *
   * Without the invalidation a deploy succeeds and customers keep the previous bundle until the
   * TTL expires - a deployment that reports success and changes nothing anyone can see, which is
   * the hardest kind to diagnose because everything says it worked.
   */
  statement {
    sid       = "StorefrontUpload"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetObject"]
    resources = [var.storefront_bucket_arn, "${var.storefront_bucket_arn}/*"]
  }

  statement {
    sid       = "StorefrontInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [var.storefront_distribution_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
