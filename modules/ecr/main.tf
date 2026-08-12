/**
 * One ECR repository per service.
 *
 * Separate repositories rather than one with tag prefixes, because the lifecycle policy, the
 * scan results and the IAM permissions are all per-repository. A single repository would mean
 * "let CI push the catalog image" and "let CI push the users image" are the same permission.
 */

resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name = "${var.name_prefix}/${each.key}"

  # IMMUTABLE, and this is the setting that matters most in this file. With mutable tags,
  # pushing `:latest` again silently changes what a task definition resolves to - so the image
  # running in production is whatever was pushed last, not what was reviewed. Rolling back
  # becomes impossible because the tag you would roll back to now points at the same image.
  #
  # The cost is that CI must tag by commit SHA rather than re-pushing `latest`. That is the
  # point.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    # Scan on push rather than on a schedule: the answer arrives while whoever pushed it is
    # still looking, which is the only time a CVE report gets acted on.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Repositories hold images that are deployed; emptying one on destroy would break a rollback
  # to an environment that still exists. Overridable for scratch environments, where a destroy
  # that fails on a non-empty repository is just an obstacle.
  force_delete = var.force_delete

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })
}

# Untagged images accumulate every time a tag is overwritten or a multi-arch build pushes
# intermediate manifests. They are billed like any other storage and nothing ever reads them.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_retention_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = { type = "expire" }
      },
      {
        # Keeps the last N *tagged* images. Deliberately generous: this is the pool a rollback
        # picks from, and an image expired an hour before it was needed costs far more than the
        # cents its storage does.
        rulePriority = 2
        description  = "Keep the ${var.tagged_image_count} most recent tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.tagged_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
