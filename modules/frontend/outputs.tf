output "bucket_name" {
  description = "Deploy target: `aws s3 sync dist/ s3://<this>/ --delete`."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = <<-EOT
    CloudFront distribution id.

    CI needs it for the invalidation that must follow every deploy. Without one, index.html is
    served from the edge cache and keeps pointing at the previous build's hashed bundles - which
    S3 no longer has, so the site 404s on its own JavaScript for whoever hits a cold edge.
  EOT
  value       = aws_cloudfront_distribution.site.id
}

output "domain_name" {
  description = "The generated *.cloudfront.net hostname. Point a Route 53 alias at this for a custom domain."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "hosted_zone_id" {
  description = "CloudFront's fixed hosted zone id, for a Route 53 alias record."
  value       = aws_cloudfront_distribution.site.hosted_zone_id
}
