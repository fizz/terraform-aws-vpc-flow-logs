# terraform-aws-vpc-flow-logs

VPC flow logs that actually deliver. Creates the destination and its authorisation, not just the flow log.

A flow log is three lines of Terraform. The reason this module exists is everything around it: `aws_flow_log` will report `ACTIVE` with `DeliverLogsStatus: SUCCESS` while writing nothing at all, because the status field describes the last delivery *attempt*, and a VPC with no traffic never attempts one. Point a flow log at a bucket with no delivery policy, or a log group that was never created, and nothing tells you until the day you need the logs.

## Usage

```hcl
module "flow_logs" {
  source  = "fizz/vpc-flow-logs/aws"
  version = "~> 0.2"

  name        = "prod"
  vpc_id      = aws_vpc.main.id
  bucket_name = "vpc-flow-logs-${data.aws_caller_identity.current.account_id}"
}
```

That creates the bucket with public access blocked, versioning on, SSE-S3, a lifecycle rule that tiers to Glacier Instant Retrieval at 90 days and expires at a year, the delivery policy the service principal needs, and a flow log emitting 27 fields as hourly hive-partitioned Parquet.

To CloudWatch Logs instead, which also creates the log group and the delivery role:

```hcl
module "flow_logs" {
  source  = "fizz/vpc-flow-logs/aws"
  version = "~> 0.2"

  name             = "cmmc"
  vpc_id           = aws_vpc.main.id
  destination_type = "cloud-watch-logs"
  log_group_name   = "/vpc/flowlogs"
}
```

## Why 27 fields

The AWS default format is version 2: fourteen fields, and not one of them can say what a flow was talking to. This module's default adds the thirteen that answer questions people actually ask.

| Field | What it buys you |
|---|---|
| `pkt-srcaddr` / `pkt-dstaddr` | `srcaddr` and `dstaddr` name the immediate hop, so everything behind a NAT gateway or a load balancer reads as a conversation with the NAT or the balancer. The `pkt-` pair names the true endpoint, which is what makes a hairpin visible rather than inferred. |
| `pkt-dst-aws-service` | AWS labels the far end (`S3`, `DYNAMODB`, `AMAZON`). Turns "35 GB/day outbound" into a named service without reverse-DNS guesswork. |
| `traffic-path` | On egress, how the packet left. |
| `flow-direction` | `ingress` or `egress` as a field, rather than inferred from which address happens to be RFC1918. |
| `instance-id`, `subnet-id`, `vpc-id` | Attribution to a workload rather than to an ENI that outlived whatever owned it. |
| `tcp-flags` | Distinguishes a completed connection from a SYN that never got a reply. |

Omitted on purpose: `sublocation-*` (Outposts and Wavelength), `ecs-*` (only populated for ECS traffic), `reject-reason` (only meaningful with `traffic_type = "REJECT"`). Every field is bytes delivered and stored, so a field nothing will ever be grouped by is a standing charge for nothing.

Override the whole list with `log_format_fields` if you want a different set.

### Reading `traffic-path`

On Nitro instances the values seen in practice are **7** (gateway VPC endpoint) and **8** (internet gateway). The documented value 2 does not appear.

An 8 is **not** by itself evidence of a NAT gateway charge — an instance in a public subnet reaches the internet gateway directly, and that is free. Anchor NAT attribution on the NAT gateway's own `interface-id` instead.

## Querying it

The `duckdb_glob` output hands back a path with the partition values already bound, so only that prefix gets listed:

```sql
SELECT pkt_dst_aws_service, sum(bytes) AS b
FROM read_parquet(
  's3://vpc-flow-logs-111122223333/raw/AWSLogs/aws-account-id=111122223333/aws-service=vpcflowlogs/aws-region=us-east-1/year=2026/month=09/day=16/*/*.parquet',
  hive_partitioning = true
)
WHERE flow_direction = 'egress'
GROUP BY 1 ORDER BY b DESC;
```

Hive-compatible partitions are on by default, so Athena partition projection and DuckDB's `hive_partitioning=true` both prune without a conversion step.

## Cost notes

Flow log volume scales with **flow count, not bytes** — one record per 5-tuple per aggregation interval. A chatty VPC full of small connections costs more to log than a quiet one moving terabytes.

- `max_aggregation_interval` defaults to **600**, the AWS default, which emits roughly a tenth the records of 60.
- Vended logs cost $0.25/GB delivered to S3 against $0.50/GB to CloudWatch Logs, and S3 storage is roughly a tenth of CloudWatch's. S3 is the default here for that reason; CloudWatch Logs earns its keep when you want a metric filter and an alarm rather than a data lake.
- Glacier **Instant Retrieval** specifically, not Flexible or Deep Archive: Athena and DuckDB both issue a plain `GET`, which the deeper tiers refuse until the object has been restored. Instant Retrieval stays directly queryable at roughly a tenth of Standard.
- `kms_key_arn` is usually the wrong trade on an S3 destination. Flow logs are network metadata about the account's own plumbing, and a customer managed key means opening its key policy to `delivery.logs.amazonaws.com` and paying a KMS request per object across a stream of many small objects. Supply one when a compliance boundary requires it, not by default. On a CloudWatch Logs destination the cost lands per `PutLogEvents` batch instead, which is far less punishing.

## Notes

- **Partition-aware.** Every ARN is built from `data.aws_partition.current`, so this works in GovCloud.
- **The VPC is not managed here.** A flow log is purely additive — `aws_flow_log` takes an id and nothing else — so this attaches to a VPC created by eksctl, the console, or another module without adopting it.
- **An S3 destination needs a trailing slash.** Without it AWS folds the last path segment into the object key, so the prefix stops separating anything. The module adds it; if you pass `existing_destination_arn`, you add it.
- Attach to a `subnet_id` or `eni_id` instead of a `vpc_id` by setting that variable instead. Exactly one is required, enforced by a precondition rather than discovered at apply time.

## Requirements

| | Version |
|---|---|
| terraform | >= 1.0 |
| aws provider | >= 5.0 |

## License

MIT
