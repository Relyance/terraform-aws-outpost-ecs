locals {
  ecs_redis_name    = "${local.name}-redis"
  ecs_redis_user    = 65532
  ecs_redis_dns_ttl = 10
  ecs_redis_subnets = local.provision_ecs_redis ? {
    for az, ids in { for id, subnet in data.aws_subnet.private : subnet.availability_zone => id... } :
    az => sort(ids)[0]
  } : {}
}

resource "aws_efs_file_system" "redis" {
  count     = local.provision_ecs_redis ? 1 : 0
  encrypted = true
  tags      = merge(local.tags, { Name = local.ecs_redis_name })
  lifecycle { prevent_destroy = true }
}

resource "aws_efs_access_point" "redis" {
  count          = local.provision_ecs_redis ? 1 : 0
  file_system_id = aws_efs_file_system.redis[0].id
  posix_user {
    uid = local.ecs_redis_user
    gid = local.ecs_redis_user
  }
  root_directory {
    path = "/redis"
    creation_info {
      owner_uid   = local.ecs_redis_user
      owner_gid   = local.ecs_redis_user
      permissions = "0700"
    }
  }
  tags = local.tags
}

resource "aws_efs_file_system_policy" "redis" {
  count          = local.provision_ecs_redis ? 1 : 0
  file_system_id = aws_efs_file_system.redis[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "elasticfilesystem:Client*"
        Resource  = aws_efs_file_system.redis[0].arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.redis[0].arn }
        Action    = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource  = aws_efs_file_system.redis[0].arn
        Condition = { StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.redis[0].arn } }
      }
    ]
  })
}

resource "aws_security_group" "redis_efs" {
  count       = local.provision_ecs_redis ? 1 : 0
  name_prefix = "${local.ecs_redis_name}-efs-"
  description = "EFS accessible only from the installation Redis service"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "redis_efs" {
  count                        = local.provision_ecs_redis ? 1 : 0
  security_group_id            = aws_security_group.redis_efs[0].id
  referenced_security_group_id = aws_security_group.redis[0].id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_vpc_security_group_egress_rule" "redis_efs" {
  count                        = local.provision_ecs_redis ? 1 : 0
  security_group_id            = aws_security_group.redis[0].id
  referenced_security_group_id = aws_security_group.redis_efs[0].id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
}

resource "aws_vpc_security_group_egress_rule" "redis_https" {
  for_each          = local.provision_ecs_redis ? var.egress_cidrs : toset([])
  security_group_id = aws_security_group.redis[0].id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_efs_mount_target" "redis" {
  for_each        = local.ecs_redis_subnets
  file_system_id  = aws_efs_file_system.redis[0].id
  subnet_id       = each.value
  security_groups = [aws_security_group.redis_efs[0].id]
}

# Keep NXDOMAIN cache lifetime short during singleton replacement. The native
# AWS provider namespace resource does not expose the Cloud Map SOA TTL.
resource "aws_cloudformation_stack" "redis_dns" {
  count = local.provision_ecs_redis ? 1 : 0
  name  = "${local.ecs_redis_name}-dns"
  template_body = jsonencode({
    Resources = {
      RedisNamespace = {
        Type = "AWS::ServiceDiscovery::PrivateDnsNamespace"
        Properties = {
          Name       = var.ecs_redis.dns_namespace
          Vpc        = var.vpc_id
          Properties = { DnsProperties = { SOA = { TTL = local.ecs_redis_dns_ttl } } }
        }
      }
    }
    Outputs = { NamespaceId = { Value = { Ref = "RedisNamespace" } } }
  })
  tags = local.tags
}

resource "aws_service_discovery_service" "redis" {
  count = local.provision_ecs_redis ? 1 : 0
  name  = "redis"
  dns_config {
    namespace_id   = aws_cloudformation_stack.redis_dns[0].outputs["NamespaceId"]
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = local.ecs_redis_dns_ttl
      type = "A"
    }
  }
  # An empty block is omitted by the provider, leaving no ECS health reporting.
  health_check_custom_config { failure_threshold = 1 }
  tags = local.tags
}

resource "aws_iam_role" "redis" {
  count              = local.provision_ecs_redis ? 1 : 0
  name               = local.ecs_redis_name
  assume_role_policy = local.task_trust
  tags               = local.tags
}

resource "aws_iam_role" "redis_execution" {
  count              = local.provision_ecs_redis ? 1 : 0
  name               = "${local.ecs_redis_name}-execution"
  assume_role_policy = local.task_trust
  tags               = local.tags
}

resource "aws_iam_role_policy" "redis_execution" {
  count = local.provision_ecs_redis ? 1 : 0
  name  = "redis-image-logs-and-startup-secrets"
  role  = aws_iam_role.redis_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      local.log_statement,
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = replace(
          var.ecs_redis.image_digest,
          "/^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com\\/(.+)@sha256:[a-f0-9]{64}$/",
          "arn:aws:ecr:$2:$1:repository/$3"
        )
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.facts.redis.secret_arn, var.exporter_redis_secret_arn, var.ecs_redis.tls_secret_arn]
      }
      ], length(var.ecs_redis.secret_kms_key_arns) > 0 ? [{
        Effect    = "Allow"
        Action    = ["kms:Decrypt"]
        Resource  = tolist(var.ecs_redis.secret_kms_key_arns)
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${local.facts.aws_region}.amazonaws.com" } }
    }] : [])
  })
}

resource "aws_ecs_task_definition" "redis" {
  count                    = local.provision_ecs_redis ? 1 : 0
  family                   = local.ecs_redis_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.ecs_redis.cpu_units
  memory                   = var.ecs_redis.memory_mib
  task_role_arn            = aws_iam_role.redis[0].arn
  execution_role_arn       = aws_iam_role.redis_execution[0].arn
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }
  volume {
    name = "data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.redis[0].id
      transit_encryption = "ENABLED"
      authorization_config {
        iam             = "ENABLED"
        access_point_id = aws_efs_access_point.redis[0].id
      }
    }
  }
  volume { name = "runtime" }
  container_definitions = jsonencode([
    {
      name                   = "redis"
      image                  = var.ecs_redis.image_digest
      essential              = true
      readonlyRootFilesystem = true
      user                   = "${local.ecs_redis_user}:${local.ecs_redis_user}"
      entryPoint             = ["/bin/sh", "-ec"]
      command                = [file("${path.module}/redis-entrypoint.sh")]
      stopTimeout            = 120
      dependsOn              = [{ containerName = "redis-init", condition = "SUCCESS" }]
      portMappings           = [{ containerPort = local.facts.redis.port, protocol = "tcp" }]
      environment = [
        { name = "REDIS_BIND", value = "0.0.0.0" },
        { name = "REDIS_PORT", value = tostring(local.facts.redis.port) },
        { name = "REDIS_HOSTNAME", value = local.redis_host },
        { name = "REDIS_DATA_DIR", value = "/data" },
        { name = "REDIS_RUNTIME_DIR", value = "/run/redis" },
        { name = "REDIS_MAX_MEMORY", value = "${floor(var.ecs_redis.memory_mib / 2)}mb" },
        { name = "REDIS_WORKER_USER", value = var.redis_worker_user_id },
        { name = "REDIS_EXPORTER_USER", value = var.redis_exporter_user_id },
        { name = "REDIS_WORKER_ACCESS", value = local.redis_worker_access },
        { name = "REDIS_EXPORTER_ACCESS", value = local.redis_exporter_access },
        { name = "REDIS_CONFIGURATION_REVISION", value = tostring(var.redis_auth_secret_version) }
      ]
      secrets = [
        { name = "REDIS_WORKER_PASSWORD", valueFrom = "${local.facts.redis.secret_arn}:password::" },
        { name = "REDIS_EXPORTER_PASSWORD", valueFrom = "${var.exporter_redis_secret_arn}:password::" },
        { name = "REDIS_TLS_CERTIFICATE", valueFrom = "${var.ecs_redis.tls_secret_arn}:certificate::" },
        { name = "REDIS_TLS_KEY", valueFrom = "${var.ecs_redis.tls_secret_arn}:private_key::" }
      ]
      mountPoints = [
        { sourceVolume = "data", containerPath = "/data", readOnly = false },
        { sourceVolume = "runtime", containerPath = "/run/redis", readOnly = false }
      ]
      healthCheck = {
        command  = ["CMD", "/bin/sh", "-ec", file("${path.module}/redis-entrypoint.sh"), "redis-entrypoint", "health"]
        interval = 30, timeout = 5, retries = 3, startPeriod = 240
      }
      logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.main.name, awslogs-region = local.facts.aws_region, awslogs-stream-prefix = "redis" } }
    },
    {
      name                   = "redis-init"
      image                  = var.ecs_redis.image_digest
      essential              = false
      readonlyRootFilesystem = true
      user                   = "0:0"
      entryPoint             = ["/bin/sh", "-ec"]
      command                = ["chown ${local.ecs_redis_user}:${local.ecs_redis_user} /run/redis && chmod 0700 /run/redis"]
      mountPoints            = [{ sourceVolume = "runtime", containerPath = "/run/redis", readOnly = false }]
    }
  ])
  tags = local.tags
}

resource "aws_ecs_service" "redis" {
  count                              = local.provision_ecs_redis ? 1 : 0
  name                               = local.ecs_redis_name
  cluster                            = local.cluster_arn
  task_definition                    = aws_ecs_task_definition.redis[0].arn
  launch_type                        = "FARGATE"
  platform_version                   = "1.4.0"
  desired_count                      = var.ecs_redis.start ? 1 : 0
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  enable_execute_command             = false
  wait_for_steady_state              = true
  service_registries { registry_arn = aws_service_discovery_service.redis[0].arn }
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.redis[0].id]
    assign_public_ip = false
  }
  depends_on = [
    terraform_data.contract,
    aws_ecs_cluster.main,
    aws_efs_file_system_policy.redis,
    aws_efs_mount_target.redis,
    aws_iam_role_policy.redis_execution,
    aws_vpc_security_group_ingress_rule.redis,
    aws_vpc_security_group_ingress_rule.redis_efs,
    aws_vpc_security_group_egress_rule.redis_efs,
    aws_vpc_security_group_egress_rule.redis_https
  ]
  tags = local.tags
}
