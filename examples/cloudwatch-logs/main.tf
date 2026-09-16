# Flow logs to CloudWatch Logs, where they can drive a metric filter and an alarm.
#
# The module creates the log group and the delivery role. Pointing a flow log at
# a log group that does not exist is the most common way to end up with a flow
# log that reports healthy and delivers nothing.

provider "aws" {
  region = "us-east-1"
}

module "flow_logs" {
  source = "../.."

  name             = "cmmc"
  vpc_id           = "vpc-0123456789abcdef0"
  destination_type = "cloud-watch-logs"

  log_group_name           = "/vpc/flowlogs"
  log_group_retention_days = 400

  # A customer managed key costs a KMS request per PutLogEvents batch rather
  # than per object, so it is far less punishing here than on an s3 destination.
  kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/abcd1234-..."

  tags = {
    Compliance = "cmmc-l2"
  }
}

output "log_group" {
  value = module.flow_logs.log_group_name
}
