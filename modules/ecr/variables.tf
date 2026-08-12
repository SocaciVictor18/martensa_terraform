variable "name_prefix" {
  description = "Prefix for repository names, e.g. martensa-dev."
  type        = string
}

variable "services" {
  description = "One repository per entry. The seven deployable images: six services plus the gateway."
  type        = list(string)

  validation {
    condition     = length(var.services) > 0
    error_message = "At least one service is required."
  }
}

variable "untagged_retention_days" {
  description = "How long an untagged image survives before the lifecycle policy expires it."
  type        = number
  default     = 7
}

variable "tagged_image_count" {
  description = "How many tagged images to keep per repository. This is the pool a rollback can choose from."
  type        = number
  default     = 20

  validation {
    condition     = var.tagged_image_count >= 5
    error_message = "Keep at least 5 tagged images; fewer leaves no meaningful rollback history."
  }
}

variable "force_delete" {
  description = "Allow `terraform destroy` to remove a repository that still holds images. Scratch environments only."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every repository."
  type        = map(string)
  default     = {}
}
