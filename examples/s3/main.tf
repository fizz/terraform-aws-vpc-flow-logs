# Flow logs to a Parquet data lake you can query with DuckDB or Athena.

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

module "flow_logs" {
  source = "../.."

  name        = "prod"
  vpc_id      = "vpc-0123456789abcdef0"
  bucket_name = "vpc-flow-logs-${data.aws_caller_identity.current.account_id}"

  # 600 is the AWS default and emits roughly a tenth the records of 60.
  max_aggregation_interval = 600

  retention_days      = 365
  days_before_archive = 90

  tags = {
    Environment = "prod"
  }
}

output "query_one_day" {
  value = module.flow_logs.duckdb_glob
}
