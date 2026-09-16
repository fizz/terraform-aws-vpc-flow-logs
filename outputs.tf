output "flow_log_id" {
  description = "The flow log resource id."
  value       = aws_flow_log.this.id
}

output "flow_log_arn" {
  description = "The flow log ARN."
  value       = aws_flow_log.this.arn
}

output "log_format" {
  description = "The format string actually sent to AWS. Useful for asserting the field order a downstream parser assumes."
  value       = local.log_format
}

output "field_count" {
  description = "How many fields each record carries. The AWS default format is 14; this module's default is 27."
  value       = length(local.fields)
}

output "bucket_name" {
  description = "Destination bucket, when this module created one."
  value       = local.create_bucket ? aws_s3_bucket.this[0].id : null
}

output "bucket_arn" {
  description = "Destination bucket ARN, when this module created one."
  value       = local.create_bucket ? aws_s3_bucket.this[0].arn : null
}

output "log_group_name" {
  description = "Destination log group, when this module created one."
  value       = local.create_log_group ? aws_cloudwatch_log_group.this[0].name : null
}

output "iam_role_arn" {
  description = "Delivery role, when this module created one."
  value       = local.create_log_group ? aws_iam_role.delivery[0].arn : null
}

output "duckdb_glob" {
  description = <<-EOT
    Read one day out of an s3 destination. The partition values are bound in the
    path, so only that prefix is listed rather than the whole bucket. Substitute
    the date, then hand it straight to read_parquet.
  EOT
  value = local.create_bucket ? join("", [
    "s3://${aws_s3_bucket.this[0].id}/${var.log_prefix}",
    "/AWSLogs/aws-account-id=${local.account_id}",
    "/aws-service=vpcflowlogs",
    "/aws-region=${local.region}",
    "/year=YYYY/month=MM/day=DD/*/*.parquet",
  ]) : null
}
