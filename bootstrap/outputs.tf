output "bucket_name" {
  description = "Put this in environments/<env>/backend.hcl as `bucket`."
  value       = aws_s3_bucket.state.id
}

output "backend_config" {
  description = "The backend.hcl contents, ready to paste. `use_lockfile` is S3-native locking; no DynamoDB table is needed."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "dev/terraform.tfstate"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}

output "account_id" {
  description = "The account this ran against, so a bucket name can embed it."
  value       = data.aws_caller_identity.current.account_id
}
