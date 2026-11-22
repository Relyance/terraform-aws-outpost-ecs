data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
locals {
  facts                       = var.installation_facts
  name                        = local.facts.deployment_id
  cluster_name                = split("/", local.facts.ecs_cluster_arn)[1]
  cluster_arn                 = local.facts.ecs_cluster_arn
  pools                       = { for p in local.facts.pools : p.role => p if p.enabled }
  fargate                     = { for role, p in local.pools : role => p if p.capacity_provider == "FARGATE" }
  ec2_pools                   = { for role, p in local.pools : role => p if p.capacity_provider != "FARGATE" }
  owned                       = { for role, p in local.ec2_pools : role => lookup(var.capacity, role, null) if contains(keys(var.capacity), role) && try(var.capacity[role].existing_provider, null) == null }
  existing                    = { for role, p in local.ec2_pools : role => lookup(var.capacity, role, null) if contains(keys(var.capacity), role) && try(var.capacity[role].existing_provider, null) != null }
  tags                        = merge(var.tags, { DeploymentId = local.name, ExecutionPlatform = "ecs" })
  provision_ecs_redis         = var.ecs_redis != null
  provision_elasticache       = var.provision_redis && !local.provision_ecs_redis
  manage_redis_security_group = local.provision_elasticache || local.provision_ecs_redis
  redis_host                  = local.provision_ecs_redis ? "redis.${var.ecs_redis.dns_namespace}" : (local.provision_elasticache ? aws_elasticache_replication_group.main[0].primary_endpoint_address : local.facts.redis.host)
  runtime_facts               = merge(local.facts, { redis = merge(local.facts.redis, { host = local.redis_host }) })
}
resource "terraform_data" "contract" {
  lifecycle {
    precondition {
      condition     = local.facts.aws_partition == "aws" && data.aws_caller_identity.current.account_id == local.facts.aws_account_id && data.aws_region.current.region == local.facts.aws_region
      error_message = "Provider account/region must match installation facts."
    }
    precondition {
      condition     = alltrue([for role in keys(local.ec2_pools) : contains(keys(var.capacity), role)])
      error_message = "Each enabled EC2 role requires an explicit capacity contract."
    }
    precondition {
      condition     = alltrue([for pool in values(local.pools) : pool.capacity_provider != "FARGATE_SPOT"])
      error_message = "Use the on-demand FARGATE capacity provider for Fargate scan roles."
    }
    precondition {
      condition = alltrue([
        for role, pool in local.fargate :
        !contains(keys(var.capacity), role) &&
        try(contains(local.fargate_memory_mib[pool.cpu_units], pool.memory_mib), false) &&
        pool.scratch_gib < var.fargate_ephemeral_storage_gib
      ])
      error_message = "Fargate roles require supported Linux task CPU/memory, scratch below the task storage allocation, and no EC2 capacity entry."
    }
    precondition {
      condition     = alltrue([for role, c in local.owned : c.ami_id != null && c.instance_type != null && contains(data.aws_ec2_instance_type.worker[role].supported_architectures, "x86_64") && data.aws_ami.worker[role].architecture == "x86_64" && data.aws_ami.worker[role].root_device_type == "ebs" && c.max_instances >= 2 && c.max_instances == floor(c.max_instances) && local.tasks_per_instance[role] >= 1 && c.max_instances * local.tasks_per_instance[role] >= local.pools[role].max_tasks && c.root_volume_gib >= 30 + local.tasks_per_instance[role] * local.pools[role].scratch_gib])
      error_message = "Owned capacity must fit tasks plus OS reserves/scratch, bound the full role maximum and allow ECS two-instance zero bootstrap."
    }
    precondition {
      condition     = alltrue([for role, c in local.existing : try(c.reservation_proof.reserved_tasks >= local.pools[role].max_tasks && c.reservation_proof.independent_child_capacity && c.reservation_proof.zero_bootstrap_supported && length(trimspace(c.reservation_proof.review_reference)) > 0 && c.existing_provider == local.pools[role].capacity_provider, false)])
      error_message = "Existing providers require exact provider name and reviewed per-role reservation/dependency/zero-bootstrap proof."
    }
    precondition {
      condition     = alltrue([for role, p in local.pools : contains(["sampler", "inventory-notification"], role) ? contains(keys(local.pools), "sampler-worker") : role == "analyzer" ? contains(keys(local.pools), "analyzer-worker") : true])
      error_message = "Enabled GAI coordinators require their independent child-worker capacity."
    }
    precondition {
      condition     = local.manage_redis_security_group || (var.existing_redis_verified && var.existing_redis_security_group_id != null)
      error_message = "Existing Redis requires explicit compatible-endpoint verification."
    }
    precondition {
      condition     = !local.provision_ecs_redis || !var.activated || try(var.ecs_redis.start, false)
      error_message = "Start and verify the ECS Redis service before activating scans."
    }
    precondition {
      condition = !local.provision_ecs_redis || try(
        contains(local.fargate_memory_mib[var.ecs_redis.cpu_units], var.ecs_redis.memory_mib) &&
        var.ecs_redis.memory_mib >= 1024 &&
        alltrue([for p in values(local.pools) : p.service_name != "${local.name}-redis"]) &&
        alltrue([for queue in local.redis_queue_names : can(regex("^[A-Za-z0-9_:.%-]+$", queue))]) &&
        var.redis_worker_user_id != var.redis_exporter_user_id &&
        alltrue([for name in [var.redis_worker_user_id, var.redis_exporter_user_id] : name != "default" && can(regex("^[A-Za-z0-9_-]+$", name))]) &&
        var.ecs_redis.tls_secret_arn != local.facts.redis.secret_arn &&
        var.ecs_redis.tls_secret_arn != var.exporter_redis_secret_arn &&
        can(regex("^arn:aws:secretsmanager:${local.facts.aws_region}:${local.facts.aws_account_id}:secret:[A-Za-z0-9/_+=.@-]+$", var.ecs_redis.tls_secret_arn)) &&
        alltrue([for arn in var.ecs_redis.secret_kms_key_arns : can(regex("^arn:aws:kms:${local.facts.aws_region}:${local.facts.aws_account_id}:key/[A-Za-z0-9-]+$", arn))]),
        false
      )
      error_message = "ECS Redis requires supported Fargate sizing, unique service/user names, literal Redis queue keys and separate regional TLS credentials."
    }
    precondition {
      condition     = var.exporter_redis_secret_arn != local.facts.redis.secret_arn && can(regex("^arn:aws:secretsmanager:${local.facts.aws_region}:${local.facts.aws_account_id}:secret:[A-Za-z0-9/_+=.@-]+$", var.exporter_redis_secret_arn))
      error_message = "Exporter requires a separate exact regional read-only ACL secret."
    }
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.private : s.availability_zone])) >= 2 && alltrue([for s in data.aws_subnet.private : s.vpc_id == var.vpc_id && !s.map_public_ip_on_launch])
      error_message = "Subnets must be private, belong to the supplied VPC and cover at least two AZs."
    }
    precondition {
      condition     = length(distinct([for role in keys(local.owned) : local.pools[role].capacity_provider])) == length(local.owned) && length(setintersection(toset([for role in keys(local.owned) : local.pools[role].capacity_provider]), toset([for c in values(local.existing) : c.existing_provider]))) == 0
      error_message = "Module-owned role providers must be independent; only reviewed supplied-provider reservations may share capacity."
    }
    precondition {
      condition     = !var.activated || alltrue([for role, p in local.pools : length(trimspace(lookup(lookup(var.application_environment, role, {}), "GAI_NOTIFICATION_TENANT", ""))) > 0 if role != "data-pipelines"])
      error_message = "Activation requires an explicitly registered tenant slug in GAI_NOTIFICATION_TENANT for each enabled GAI role. It cannot be derived from tenant_record_id."
    }
    precondition {
      condition     = !var.activated || !contains(keys(local.pools), "data-pipelines") || length(trimspace(lookup(lookup(var.application_environment, "data-pipelines", {}), "DP_TENANT", ""))) > 0
      error_message = "Activation requires explicit DP_TENANT registered tenant slug for Data Pipelines; tenant_record_id cannot supply it."
    }
    precondition {
      condition     = var.create_cluster || !var.manage_cluster_capacity_association
      error_message = "Existing clusters retain external association ownership; associate these providers explicitly before activation."
    }
  }
}
resource "aws_ecs_cluster" "main" {
  count = var.create_cluster ? 1 : 0
  name  = local.cluster_name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.tags
}
