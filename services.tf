locals {
  fargate_memory_mib = {
    256   = [512, 1024, 2048]
    512   = range(1024, 4097, 1024)
    1024  = range(2048, 8193, 1024)
    2048  = range(4096, 16385, 1024)
    4096  = range(8192, 30721, 1024)
    8192  = range(16384, 61441, 4096)
    16384 = range(32768, 122881, 8192)
    32768 = [61440, 122880, 249856]
  }
  worker_users = { for role in keys(local.pools) : role => lookup(var.runtime_users, role, { uid = 65532, gid = 65532 }) }
  worker_python = { for role in keys(local.pools) : role => (
    role == "data-pipelines" && contains(keys(local.fargate), role) ? "/app/.venv/bin/python" : "python"
  ) }
  scratch_mount = [{ sourceVolume = "scratch", containerPath = "/scratch", readOnly = false }]
  common_environment = [
    { name = "INHOST_EXECUTION_PLATFORM", value = "ecs" },
    { name = "RUNTIME_MODE", value = "inhost" },
    { name = "IS_SHARED_ENV", value = "false" },
    { name = "RUNTIME_CLOUD", value = "AWS" },
    { name = "INHOST_DEPLOYMENT_ID", value = local.name },
    { name = "INHOST_ROUTE_REVISION", value = tostring(local.facts.route_revision) },
    { name = "PUBSUB_PROJECT_ID", value = local.facts.execution_project_id },
    { name = "AWS_REGION", value = local.facts.aws_region },
    { name = "AWS_DEFAULT_REGION", value = local.facts.aws_region },
    { name = "AWS_STS_REGIONAL_ENDPOINTS", value = "regional" },
    { name = "AWS_EC2_METADATA_DISABLED", value = "true" },
    { name = "REDIS_HOST", value = local.redis_host },
    { name = "REDIS_PORT", value = tostring(local.facts.redis.port) },
    { name = "INHOST_REDIS_TLS", value = "true" }
  ]
}
resource "aws_ecs_task_definition" "worker" {
  for_each                 = local.pools
  family                   = "${local.name}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = [contains(keys(local.fargate), each.key) ? "FARGATE" : "EC2"]
  cpu                      = each.value.cpu_units
  memory                   = each.value.memory_mib
  task_role_arn            = each.value.task_role_arn
  execution_role_arn       = aws_iam_role.execution.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  volume {
    name = "scratch"
    dynamic "docker_volume_configuration" {
      for_each = contains(keys(local.ec2_pools), each.key) ? [true] : []
      content {
        scope  = "task"
        driver = "local"
      }
    }
  }
  dynamic "ephemeral_storage" {
    for_each = contains(keys(local.fargate), each.key) ? [var.fargate_ephemeral_storage_gib] : []
    content { size_in_gib = ephemeral_storage.value }
  }
  container_definitions = jsonencode(concat(
    [merge(
      {
        name        = each.key
        image       = each.value.image_digest
        essential   = true
        cpu         = each.value.cpu_units
        memory      = each.value.memory_mib
        entryPoint  = [local.worker_python[each.key], "-m", "inhost_runtime.bootstrap"]
        command     = [each.key]
        stopTimeout = contains(keys(local.fargate), each.key) ? 120 : 600
        user        = "${local.worker_users[each.key].uid}:${local.worker_users[each.key].gid}"
        privileged  = false
        mountPoints = local.scratch_mount
        environment = concat(local.common_environment, [
          { name = "INHOST_WORKER_ROLE", value = each.key },
          { name = "IDENTITY_SERVICE_WORKLOAD_AUDIENCE", value = "int://identity/workloads/${local.name}/${each.key}" },
          { name = "INHOST_DRAIN_BUDGET_SECONDS", value = contains(keys(local.fargate), each.key) ? "90" : "540" },
          { name = "INHOST_AWS_PYTHON", value = "/opt/inhost-aws/bin/python" },
          { name = "INHOST_INSTALLATION_FACTS_JSON", value = jsonencode(local.runtime_facts) },
          { name = "INHOST_REDIS_SECRET_ARN", value = local.facts.redis.secret_arn },
          { name = "RUN_JOB_MODE", value = "true" },
          { name = "GAI_DISTRIBUTED_RUN_JOB_MODE", value = "true" },
          { name = "TMPDIR", value = "/scratch" }
        ], each.key == "data-pipelines" && var.enable_versioned_inventory_result_cleanup ? [{ name = "DP_INHOST_VERSIONED_RESULT_CLEANUP", value = "true" }] : [], contains(["sampler", "inventory-notification"], each.key) ? [{ name = "GAI_PUBSUB_TOPIC_ID", value = each.key == "sampler" ? "gai-pipelines-gai-sampler" : "data-pipelines-notification-gai" }] : [], [for name, value in lookup(var.application_environment, each.key, {}) : { name = name, value = value }])
        logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.main.name, awslogs-region = local.facts.aws_region, awslogs-stream-prefix = each.key } }
      },
      contains(keys(local.fargate), each.key) ? {
        dependsOn = [{ containerName = "scratch-init", condition = "SUCCESS" }]
      } : {}
    )],
    contains(keys(local.fargate), each.key) ? [{
      name       = "scratch-init"
      image      = each.value.image_digest
      essential  = false
      user       = "0:0"
      entryPoint = [local.worker_python[each.key], "-c"]
      command = [
        "import os, sys; os.chown('/scratch', int(sys.argv[1]), int(sys.argv[2])); os.chmod('/scratch', 0o700)",
        tostring(local.worker_users[each.key].uid),
        tostring(local.worker_users[each.key].gid)
      ]
      mountPoints      = local.scratch_mount
      logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.main.name, awslogs-region = local.facts.aws_region, awslogs-stream-prefix = "${each.key}-init" } }
    }] : []
  ))
  tags = local.tags
}
resource "aws_ecs_service" "worker" {
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true
  scheduling_strategy                = "REPLICA"
  for_each                           = local.pools
  name                               = each.value.service_name
  cluster                            = local.cluster_arn
  task_definition                    = aws_ecs_task_definition.worker[each.key].arn
  desired_count                      = 0
  platform_version                   = contains(keys(local.fargate), each.key) ? "1.4.0" : null
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = false
  capacity_provider_strategy {
    capacity_provider = each.value.capacity_provider
    weight            = 1
    base              = 0
  }
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }
  # Owned providers dedicate one instance per role task. This makes the validated
  # scratch/OS reservations enforceable rather than assuming scheduler headroom.
  dynamic "placement_constraints" {
    for_each = contains(keys(local.owned), each.key) ? [true] : []
    content { type = "distinctInstance" }
  }
  dynamic "ordered_placement_strategy" {
    for_each = contains(keys(local.ec2_pools), each.key) ? [true] : []
    content {
      type  = "binpack"
      field = "memory"
    }
  }
  tags = merge(local.tags, { WorkerRole = each.key })
  lifecycle { ignore_changes = [desired_count] }
  depends_on = [terraform_data.contract, aws_ecs_cluster.main, aws_ecs_cluster_capacity_providers.main, aws_ecs_capacity_provider.worker, aws_iam_role_policy.worker, aws_iam_role_policy.execution]
}
resource "aws_ecs_task_definition" "exporter" {
  family                   = "${local.name}-exporter"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  task_role_arn            = local.facts.exporter.task_role_arn
  execution_role_arn       = aws_iam_role.execution.arn
  container_definitions = jsonencode([{
    name        = "exporter"
    image       = local.facts.exporter.image_digest
    essential   = true
    entryPoint  = ["python", "-m", "inhost_metrics_exporter"]
    command     = []
    stopTimeout = 30
    user        = "10001:10001"
    environment = concat(local.common_environment, [
      { name = "INHOST_WORKER_ROLE", value = "exporter" },
      { name = "INHOST_DRAIN_BUDGET_SECONDS", value = "540" },
      { name = "INHOST_REDIS_SECRET_ARN", value = var.exporter_redis_secret_arn },
      { name = "INHOST_INSTALLATION_FACTS_JSON", value = jsonencode(merge(local.runtime_facts, { redis = merge(local.runtime_facts.redis, { secret_arn = var.exporter_redis_secret_arn }) })) }
    ], length(var.pubsub_global_zero_subscriptions) == 0 ? [] : [{ name = "INHOST_PUBSUB_GLOBAL_ZERO_SUBSCRIPTIONS_JSON", value = jsonencode(sort(tolist(var.pubsub_global_zero_subscriptions))) }])
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.main.name, awslogs-region = local.facts.aws_region, awslogs-stream-prefix = "exporter" } }
  }])
  tags = local.tags
}
resource "aws_ecs_service" "exporter" {
  propagate_tags                     = "SERVICE"
  enable_ecs_managed_tags            = true
  scheduling_strategy                = "REPLICA"
  name                               = "${local.name}-exporter"
  cluster                            = local.cluster_arn
  task_definition                    = aws_ecs_task_definition.exporter.arn
  desired_count                      = var.activated ? 1 : 0
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = false
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }
  tags       = local.tags
  depends_on = [terraform_data.contract, aws_ecs_cluster.main, aws_iam_role_policy.exporter, aws_iam_role_policy.execution]
}
