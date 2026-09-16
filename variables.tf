# ---------------------------------------------------------------------------
# What to watch
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for created resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC to attach the flow log to. Set exactly one of vpc_id, subnet_id, eni_id."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet to attach the flow log to. Set exactly one of vpc_id, subnet_id, eni_id."
  type        = string
  default     = null
}

variable "eni_id" {
  description = "Network interface to attach the flow log to. Set exactly one of vpc_id, subnet_id, eni_id."
  type        = string
  default     = null
}

variable "traffic_type" {
  description = "Which flows to capture: ACCEPT, REJECT, or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.traffic_type)
    error_message = "traffic_type must be ACCEPT, REJECT, or ALL."
  }
}

variable "max_aggregation_interval" {
  description = <<-EOT
    Seconds a flow is aggregated before a record is emitted. Only 60 and 600 are
    accepted by AWS. Record volume scales with flow count, not bytes, so 60
    produces roughly ten times the records of 600 for the same traffic.
  EOT
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.max_aggregation_interval)
    error_message = "max_aggregation_interval must be 60 or 600."
  }
}

# ---------------------------------------------------------------------------
# Where it goes
# ---------------------------------------------------------------------------

variable "destination_type" {
  description = "s3 or cloud-watch-logs."
  type        = string
  default     = "s3"

  validation {
    condition     = contains(["s3", "cloud-watch-logs"], var.destination_type)
    error_message = "destination_type must be s3 or cloud-watch-logs."
  }
}

variable "create_destination" {
  description = <<-EOT
    Create the destination (bucket, or log group plus its delivery role) rather
    than attaching to one that already exists. When false, supply
    existing_destination_arn.
  EOT
  type        = bool
  default     = true
}

variable "existing_destination_arn" {
  description = <<-EOT
    Used when create_destination is false. For s3, a bucket ARN with the key
    prefix and a trailing slash. For cloud-watch-logs, a log group ARN; pair it
    with existing_iam_role_arn.
  EOT
  type        = string
  default     = null
}

variable "existing_iam_role_arn" {
  description = "Delivery role for an existing CloudWatch Logs destination. Ignored for s3."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# S3 destination
# ---------------------------------------------------------------------------

variable "bucket_name" {
  description = "Destination bucket when destination_type is s3 and create_destination is true."
  type        = string
  default     = null
}

variable "log_prefix" {
  description = "Key prefix under which flow logs land, leaving the bucket root free for a curated prefix or a table location."
  type        = string
  default     = "raw"
}

variable "file_format" {
  description = "parquet or plain-text. Parquet is columnar and prunes on read."
  type        = string
  default     = "parquet"

  validation {
    condition     = contains(["parquet", "plain-text"], var.file_format)
    error_message = "file_format must be parquet or plain-text."
  }
}

variable "hive_compatible_partitions" {
  description = "Emit key=value path segments so Athena partition projection and DuckDB hive_partitioning both prune without a conversion step."
  type        = bool
  default     = true
}

variable "per_hour_partition" {
  description = "Partition hourly rather than daily. Pays off once one day of records stops fitting comfortably in a single scan."
  type        = bool
  default     = true
}

variable "days_before_archive" {
  description = "Days in Standard before transition to Glacier Instant Retrieval. Null disables the transition."
  type        = number
  default     = 90
}

variable "retention_days" {
  description = "Days before flow log objects expire. Null disables expiry."
  type        = number
  default     = 365
}

variable "noncurrent_retention_days" {
  description = "Days before superseded object versions expire. Versioning is on, so without this they accumulate behind the current objects indefinitely."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# CloudWatch Logs destination
# ---------------------------------------------------------------------------

variable "log_group_name" {
  description = "Log group to deliver to when destination_type is cloud-watch-logs. Defaults to /aws/vpc-flow-logs/<name>."
  type        = string
  default     = null
}

variable "log_group_retention_days" {
  description = "CloudWatch Logs retention. 0 means never expire, which is rarely what anyone wants and is the AWS default."
  type        = number
  default     = 365
}

# ---------------------------------------------------------------------------
# Encryption
# ---------------------------------------------------------------------------

variable "kms_key_arn" {
  description = <<-EOT
    Customer managed key for the destination. Null uses SSE-S3 for a bucket and
    CloudWatch's service-managed encryption for a log group.

    For s3 this is usually the wrong trade: flow logs are network metadata about
    the account's own plumbing, and a CMK means opening its key policy to
    delivery.logs.amazonaws.com and paying a KMS request per object across a
    stream of many small objects. Supply one when a compliance boundary requires
    a customer managed key, not by default.
  EOT
  type        = string
  default     = null
}

variable "log_format_fields" {
  description = "Override the emitted field list. Empty uses the module's v5 field set, documented in main.tf."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
