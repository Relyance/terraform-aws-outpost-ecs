locals {
  task_trust                   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" }, Action = "sts:AssumeRole", Condition = { StringEquals = { "aws:SourceAccount" = local.facts.aws_account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ecs:${local.facts.aws_region}:${local.facts.aws_account_id}:*" } } }] })
  federation_statement         = { Effect = "Allow", Action = ["sts:GetWebIdentityToken"], Resource = "*", Condition = { "ForAllValues:StringEquals" = { "sts:IdentityTokenAudience" = [local.facts.federation.audience] }, "Null" = { "sts:IdentityTokenAudience" = "false" }, NumericLessThanEquals = { "sts:DurationSeconds" = 900 }, StringEquals = { "aws:RequestedRegion" = local.facts.aws_region } } }
  ecr_repositories             = distinct([for w in concat(local.facts.pools, [local.facts.exporter]) : "arn:aws:ecr:${regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/(.+)@sha256:", w.image_digest)[1]}:${regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/(.+)@sha256:", w.image_digest)[0]}:repository/${regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/(.+)@sha256:", w.image_digest)[2]}" if can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/", w.image_digest))])
  stores                       = concat([local.facts.work_store, local.facts.findings_store], [for name in ["inventory_store", "outbox_store"] : local.facts[name] if try(local.facts[name], null) != null])
  inventory_result_cleanup_arn = try("arn:aws:s3:::${local.facts.outbox_store.bucket}/${trimsuffix(local.facts.outbox_store.prefix, "/")}/__outbox__/root_run=*/results/resource_type=*/partition=*/work=*/attempt=*/batch=*.parquet", null)
  store_bucket_arns            = distinct([for store in local.stores : "arn:aws:s3:::${store.bucket}"])
  store_object_arns            = distinct([for store in local.stores : "arn:aws:s3:::${store.bucket}/${store.prefix}*"])
  store_context_arns           = distinct(flatten([for store in local.stores : ["arn:aws:s3:::${store.bucket}", "arn:aws:s3:::${store.bucket}/${store.prefix}*"]]))
  store_via_services           = distinct([for store in local.stores : "s3.${store.region}.amazonaws.com"])
  store_statements = concat([
    { Effect = "Allow", Action = ["s3:GetBucketLocation"], Resource = local.store_bucket_arns }
    ], [for store in local.stores : { Effect = "Allow", Action = ["s3:ListBucket"], Resource = "arn:aws:s3:::${store.bucket}", Condition = { StringLike = { "s3:prefix" = ["${store.prefix}*"] } } }], [
    { Effect = "Allow", Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:AbortMultipartUpload"], Resource = local.store_object_arns }
  ])
  log_statement = { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:${local.facts.aws_region}:${local.facts.aws_account_id}:log-group:${aws_cloudwatch_log_group.main.name}:*" }
}
resource "aws_iam_role" "worker" {
  for_each           = local.pools
  name               = split("/", each.value.task_role_arn)[1]
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role" "exporter" {
  name               = split("/", local.facts.exporter.task_role_arn)[1]
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = local.task_trust
  tags               = local.tags
}
resource "aws_iam_role_policy" "execution" {
  name = "image-and-log-startup"
  role = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    local.log_statement
  ], length(local.ecr_repositories) == 0 ? [] : [{ Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"], Resource = local.ecr_repositories }]) })
}
resource "aws_iam_role_policy" "worker" {
  for_each = local.pools
  name     = "inhost-runtime"
  role     = aws_iam_role.worker[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    local.federation_statement,
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = concat([local.facts.redis.secret_arn], tolist(lookup(var.source_secret_arns, each.key, []))) },
    { Effect = "Allow", Action = ["ecs:GetTaskProtection", "ecs:UpdateTaskProtection"], Resource = "arn:aws:ecs:${local.facts.aws_region}:${local.facts.aws_account_id}:task/${local.cluster_name}/*", Condition = { ArnEquals = { "ecs:cluster" = local.cluster_arn }, StringEquals = { "aws:ResourceTag/DeploymentId" = local.name, "aws:ResourceTag/WorkerRole" = each.key } } }
    ], local.store_statements,
    # Acknowledge only document-type sidecars after their Delta commit barrier.
    # Durable findings, other stores and source objects retain no delete grant.
    contains(["analyzer", "analyzer-worker"], each.key) ? [{
      Effect   = "Allow", Action = ["s3:DeleteObject"],
      Resource = ["arn:aws:s3:::${local.facts.findings_store.bucket}/${join("/", compact([replace(local.facts.findings_store.prefix, "/[/]+$/", ""), "gai_document_type_pending", "*"]))}"]
    }] : [],
    each.key == "data-pipelines" && var.enable_versioned_inventory_result_cleanup ? [{
      Effect   = "Allow", Action = ["s3:DeleteObjectVersion"],
      Resource = [local.inventory_result_cleanup_arn]
    }] : [],
    length(lookup(var.source_role_arns, each.key, [])) == 0 ? [] : [
      { Effect = "Allow", Action = ["sts:AssumeRole"], Resource = tolist(var.source_role_arns[each.key]) }
      ], length(var.store_kms_key_arns) == 0 ? [] : [
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = tolist(var.store_kms_key_arns), Condition = { StringEquals = { "kms:ViaService" = local.store_via_services }, StringLike = { "kms:EncryptionContext:aws:s3:arn" = local.store_context_arns } } }
      ], length(lookup(var.secret_kms_key_arns, each.key, [])) == 0 ? [] : [
      { Effect = "Allow", Action = ["kms:Decrypt"], Resource = tolist(var.secret_kms_key_arns[each.key]) }
  ]) })
}
resource "aws_iam_role_policy" "exporter" {
  name = "metrics-only"
  role = aws_iam_role.exporter.id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    local.federation_statement,
    { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "Relyance/InHost" } } },
    { Effect = "Allow", Action = ["ecs:DescribeServices"], Resource = [for p in values(local.pools) : "arn:aws:ecs:${local.facts.aws_region}:${local.facts.aws_account_id}:service/${local.cluster_name}/${p.service_name}"], Condition = { ArnEquals = { "ecs:cluster" = local.cluster_arn } } },
    # ListTasks has no serviceName IAM condition; scope cluster and filter exact services in the collector.
    { Effect = "Allow", Action = ["ecs:ListTasks"], Resource = "*", Condition = { ArnEquals = { "ecs:cluster" = local.cluster_arn } } },
    { Effect = "Allow", Action = ["ecs:DescribeTasks"], Resource = "arn:aws:ecs:${local.facts.aws_region}:${local.facts.aws_account_id}:task/${local.cluster_name}/*", Condition = { ArnEquals = { "ecs:cluster" = local.cluster_arn }, StringEquals = { "aws:ResourceTag/DeploymentId" = local.name } } },
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = var.exporter_redis_secret_arn }
  ], length(lookup(var.secret_kms_key_arns, "exporter", [])) == 0 ? [] : [{ Effect = "Allow", Action = ["kms:Decrypt"], Resource = tolist(var.secret_kms_key_arns["exporter"]) }]) })
}
resource "aws_iam_role" "instance" {
  for_each           = local.owned
  name               = "${local.name}-${each.key}-instance"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "instance" {
  for_each   = local.owned
  role       = aws_iam_role.instance[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}
resource "aws_iam_instance_profile" "worker" {
  for_each = local.owned
  name     = "${local.name}-${each.key}"
  role     = aws_iam_role.instance[each.key].name
}
