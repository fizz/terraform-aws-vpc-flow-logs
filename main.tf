# VPC flow logs, to S3 or to CloudWatch Logs, with the destination built for you.
#
# The flow log resource itself is three lines. Everything else in this module is
# the destination and the authorisation, which is where flow logs actually go
# wrong: aws_flow_log will happily report ACTIVE while delivering nothing,
# because the thing it delivers to was never created and nothing checks.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  # .name over .region deliberately. .region needs AWS provider 6.x, and
  # pinning this module to a major provider version for one string locks out
  # every caller still on 5.x. .name works in both and only warns on 6.
  region = data.aws_region.current.name

  # Exactly one target. aws_flow_log accepts one of these, and passing none
  # produces an API error at apply time rather than a plan-time complaint.
  target_count = length(compact([var.vpc_id, var.subnet_id, var.eni_id]))

  to_s3  = var.destination_type == "s3"
  to_cwl = var.destination_type == "cloud-watch-logs"

  create_bucket    = local.to_s3 && var.create_destination
  create_log_group = local.to_cwl && var.create_destination

  bucket_arn = local.create_bucket ? "arn:${local.partition}:s3:::${var.bucket_name}" : null

  # The trailing slash decides whether the prefix is a prefix. Without it AWS
  # folds the last path segment into the object key instead.
  s3_destination = local.create_bucket ? "${local.bucket_arn}/${var.log_prefix}/" : var.existing_destination_arn

  log_group_name = coalesce(var.log_group_name, "/aws/vpc-flow-logs/${var.name}")

  cwl_destination = local.create_log_group ? aws_cloudwatch_log_group.this[0].arn : var.existing_destination_arn
  cwl_role_arn    = local.create_log_group ? aws_iam_role.delivery[0].arn : var.existing_iam_role_arn

  destination = local.to_s3 ? local.s3_destination : local.cwl_destination

  # -------------------------------------------------------------------------
  # Log format
  #
  # The AWS default is version 2: fourteen fields, and not one of them can say
  # what a flow was talking to. The additions below are picked, not swept in.
  # Every field is bytes delivered and stored, so a field nothing will ever be
  # grouped by is a standing charge for nothing.
  #
  #   pkt-srcaddr / pkt-dstaddr  srcaddr and dstaddr name the immediate hop, so
  #                              everything behind a NAT gateway or a load
  #                              balancer reads as a conversation with the NAT or
  #                              the balancer. The pkt- pair names the true
  #                              endpoint, which is what makes a hairpin visible
  #                              rather than inferred.
  #   pkt-dst-aws-service        AWS labels the far end (S3, DYNAMODB, AMAZON).
  #                              Turns "35 GB/day outbound" into a named service
  #                              without reverse-DNS guesswork.
  #   traffic-path               On egress, how the packet left. On Nitro the
  #                              values seen in practice are 7 (gateway VPC
  #                              endpoint) and 8 (internet gateway); the
  #                              documented 2 does not appear. An 8 is not by
  #                              itself a NAT charge, because an instance in a
  #                              public subnet reaches the IGW directly. Anchor
  #                              NAT attribution on the NAT gateway's own
  #                              interface-id instead.
  #   flow-direction             ingress or egress as a field, rather than
  #                              inferred from which address happens to be
  #                              RFC1918.
  #   instance-id / subnet-id    Attribution to a workload rather than to an ENI
  #                              that outlived the thing that owned it.
  #
  # Left out on purpose: sublocation-* (Outposts and Wavelength), ecs-* (only
  # populated for ECS traffic), reject-reason (only meaningful with traffic_type
  # REJECT).
  # -------------------------------------------------------------------------
  default_fields = [
    "version", "account-id", "interface-id",
    "srcaddr", "dstaddr", "srcport", "dstport", "protocol",
    "packets", "bytes", "start", "end", "action", "log-status",
    "vpc-id", "subnet-id", "instance-id", "tcp-flags", "type",
    "pkt-srcaddr", "pkt-dstaddr", "region", "az-id",
    "pkt-src-aws-service", "pkt-dst-aws-service",
    "flow-direction", "traffic-path",
  ]

  fields = length(var.log_format_fields) > 0 ? var.log_format_fields : local.default_fields

  # $${ escapes to a literal ${ so AWS receives its own placeholder rather than
  # Terraform trying to interpolate it. Built by join so the list above stays the
  # single source of truth.
  log_format = join(" ", [for f in local.fields : "$${${f}}"])
}

resource "terraform_data" "exactly_one_target" {
  lifecycle {
    precondition {
      condition     = local.target_count == 1
      error_message = "Set exactly one of vpc_id, subnet_id, eni_id."
    }

    precondition {
      condition     = var.create_destination || var.existing_destination_arn != null
      error_message = "create_destination is false, so existing_destination_arn is required."
    }

    precondition {
      condition     = !local.create_bucket || var.bucket_name != null
      error_message = "destination_type is s3 and create_destination is true, so bucket_name is required."
    }
  }
}

# ===========================================================================
# S3 destination
# ===========================================================================

resource "aws_s3_bucket" "this" {
  count  = local.create_bucket ? 1 : 0
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  count                   = local.create_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.this[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.this[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.this[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

# Standard for the window anyone actually investigates in, then Glacier Instant
# Retrieval rather than Flexible or Deep Archive: Athena and DuckDB both issue a
# plain GET, which the deeper tiers refuse until the object has been restored.
# Instant Retrieval stays directly queryable at roughly a tenth of Standard.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.this[0].id

  rule {
    id     = "tier-and-expire"
    status = "Enabled"

    filter {
      prefix = "${var.log_prefix}/"
    }

    dynamic "transition" {
      for_each = var.days_before_archive == null ? [] : [var.days_before_archive]
      content {
        days          = transition.value
        storage_class = "GLACIER_IR"
      }
    }

    dynamic "expiration" {
      for_each = var.retention_days == null ? [] : [var.retention_days]
      content {
        days = expiration.value
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# ---------------------------------------------------------------------------
# Delivery policy
#
# This is the part the console does for you and Terraform does not. A flow log
# is a vended log: the write arrives as the service principal
# delivery.logs.amazonaws.com, never as a role in this account, so the bucket
# policy is the entire authorisation. Create the bucket in Terraform without
# this and delivery fails with no error anyone sees: with no traffic there is
# no delivery attempt, so DeliverLogsStatus stays at SUCCESS.
#
# SourceAccount and SourceArn are what stop another account naming this bucket
# as its delivery target.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  count = local.create_bucket ? 1 : 0

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    # Two shapes, because hive_compatible_partitions changes the delivery path.
    # With it on, objects land under AWSLogs/aws-account-id=<id>/; with it off,
    # under AWSLogs/<id>/. Granting only one means AWS silently appends its own
    # statement to make delivery work, and the next terraform apply removes it
    # again. Granting both keeps the policy stable across either setting.
    resources = [
      "${local.bucket_arn}/${var.log_prefix}/AWSLogs/${local.account_id}/*",
      "${local.bucket_arn}/${var.log_prefix}/AWSLogs/aws-account-id=${local.account_id}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [local.bucket_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:*"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  count  = local.create_bucket ? 1 : 0
  bucket = aws_s3_bucket.this[0].id
  policy = data.aws_iam_policy_document.bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ===========================================================================
# CloudWatch Logs destination
#
# Delivery here is not a vended log: it runs as an IAM role in this account, so
# the role is the authorisation and the log group has to exist first. A flow log
# pointed at a log group that was never created reports ACTIVE with
# DeliverLogsStatus SUCCESS for as long as no packet crosses the VPC, which is
# indefinitely in an empty one.
# ===========================================================================

resource "aws_cloudwatch_log_group" "this" {
  count             = local.create_log_group ? 1 : 0
  name              = local.log_group_name
  retention_in_days = var.log_group_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "assume" {
  count = local.create_log_group ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "delivery" {
  count = local.create_log_group ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.this[0].arn}:*"]
  }
}

resource "aws_iam_role" "delivery" {
  count              = local.create_log_group ? 1 : 0
  name               = "${var.name}-flow-logs-delivery"
  assume_role_policy = data.aws_iam_policy_document.assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "delivery" {
  count  = local.create_log_group ? 1 : 0
  name   = "deliver-to-${replace(trimprefix(local.log_group_name, "/"), "/", "-")}"
  role   = aws_iam_role.delivery[0].id
  policy = data.aws_iam_policy_document.delivery[0].json
}

# ===========================================================================
# The flow log
# ===========================================================================

resource "aws_flow_log" "this" {
  vpc_id       = var.vpc_id
  subnet_id    = var.subnet_id
  eni_id       = var.eni_id
  traffic_type = var.traffic_type

  log_destination_type     = var.destination_type
  log_destination          = local.destination
  iam_role_arn             = local.to_cwl ? local.cwl_role_arn : null
  log_format               = local.log_format
  max_aggregation_interval = var.max_aggregation_interval

  # Only meaningful for s3. Setting it on a CloudWatch Logs flow log is rejected.
  dynamic "destination_options" {
    for_each = local.to_s3 ? [1] : []
    content {
      file_format                = var.file_format
      per_hour_partition         = var.per_hour_partition
      hive_compatible_partitions = var.hive_compatible_partitions
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-flow-log" })

  # Both destinations need their authorisation in place before the first
  # delivery, and neither failure is loud.
  depends_on = [
    aws_s3_bucket_policy.this,
    aws_iam_role_policy.delivery,
    terraform_data.exactly_one_target,
  ]
}
