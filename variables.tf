variable "installation_facts" {
  description = "Validated nonsecret installation-v1 facts. Role ARNs must name the roles this module owns; issuer is externally configured."
  type        = any
  validation {
    condition     = try(var.installation_facts.schema_version == 1 && var.installation_facts.execution_platform == "ecs" && var.installation_facts.runtime_mode == "inhost", false)
    error_message = "Only ECS installation schema v1 with runtime_mode=inhost is supported."
  }
  validation {
    condition     = try(var.installation_facts.ecs_cluster_arn == "arn:aws:ecs:${var.installation_facts.aws_region}:${var.installation_facts.aws_account_id}:cluster/${split("/", var.installation_facts.ecs_cluster_arn)[1]}" && length(regexall("^[a-z][a-z0-9-]{0,19}$", var.installation_facts.deployment_id)) == 1, false)
    error_message = "Deployment name and exact same-account regional cluster ARN are required."
  }
  validation {
    condition     = try(length(var.installation_facts.pools) > 0 && length(distinct([for p in var.installation_facts.pools : p.role])) == length(var.installation_facts.pools) && length(distinct([for p in var.installation_facts.pools : p.service_name])) == length(var.installation_facts.pools) && alltrue([for p in var.installation_facts.pools : contains(["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"], p.role) && p.min_tasks == 0 && p.max_tasks > 0 && p.max_tasks == floor(p.max_tasks) && p.cpu_units > 0 && p.memory_mib > 0 && p.scratch_gib > 0 && p.slots_per_task == (p.role == "data-pipelines" ? 2 : 1) && (p.role != "inventory-notification" || p.source.kind == "pubsub") && p.run_job_mode && p.distributed_run_job_mode]), false)
    error_message = "Pools need unique role/service names, positive explicit sizing/caps, zero minima, GAI slots1/DP slots2 and both job-mode flags true."
  }
  validation {
    condition     = try(alltrue([for p in var.installation_facts.pools : p.service_name != "${var.installation_facts.deployment_id}-exporter"]), false)
    error_message = "Worker services cannot use the installation's exporter service name."
  }
  validation {
    condition     = try(alltrue([for p in var.installation_facts.pools : p.source.deployment_id == var.installation_facts.deployment_id && p.source.route_revision == var.installation_facts.route_revision && p.source.execution_project_id == var.installation_facts.execution_project_id && (p.source.kind == "pubsub" ? startswith(p.source.subscription_path, "projects/${var.installation_facts.execution_project_id}/subscriptions/") && length(p.source.storage_regions) > 0 : p.source.kind == "redis" && p.source.database == 0 && length(p.source.queue_name) > 0)]), false)
    error_message = "Each exact source must match installation deployment/project/revision, with regional Pub/Sub coverage or Redis DB0."
  }
  validation {
    condition     = try(alltrue([for w in concat(var.installation_facts.pools, [var.installation_facts.exporter]) : can(regex("^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$", w.image_digest)) && can(regex("^arn:aws:iam::${var.installation_facts.aws_account_id}:role/[A-Za-z0-9_+=,.@-]+$", w.task_role_arn))]) && length(distinct([for w in concat(var.installation_facts.pools, [var.installation_facts.exporter]) : w.task_role_arn])) == length(var.installation_facts.pools) + 1 && can(regex("^https://[a-z0-9-]+\\.tokens\\.sts\\.global\\.api\\.aws$", var.installation_facts.federation.issuer)), false)
    error_message = "Require immutable images, dedicated exact same-account roles without IAM paths, and externally configured account issuer."
  }
  validation {
    condition     = try(var.installation_facts.redis.tls && !var.installation_facts.redis.cluster_mode && var.installation_facts.redis.broker_db == 0 && var.installation_facts.redis.results_db == 1 && var.installation_facts.redis.coordination_db == 2 && var.installation_facts.redis.data_pipelines_db == 3 && can(regex("^arn:aws:secretsmanager:${var.installation_facts.aws_region}:${var.installation_facts.aws_account_id}:secret:[A-Za-z0-9/_+=.@-]+$", var.installation_facts.redis.secret_arn)) && length(regexall("\"(password|token|secret_value|secret_string|private_key|access_key)\"", jsonencode(var.installation_facts))) == 0, false)
    error_message = "Redis requires TLS, authentication reference, cluster mode off and DB0/1/2/3; facts must not contain credentials."
  }
  validation {
    condition     = try(alltrue([for p in var.installation_facts.pools : p.task_role_arn == "arn:aws:iam::${var.installation_facts.aws_account_id}:role/${var.installation_facts.deployment_id}-${p.role}"]) && var.installation_facts.exporter.task_role_arn == "arn:aws:iam::${var.installation_facts.aws_account_id}:role/${var.installation_facts.deployment_id}-exporter" && length(distinct([for w in concat(var.installation_facts.pools, [var.installation_facts.exporter]) : w.google_service_account])) == length(var.installation_facts.pools) + 1, false)
    error_message = "Workload roles must be deployment-qualified <deployment>-<role> names and use distinct Google identities."
  }

  validation {
    condition     = try(!anytrue([for p in var.installation_facts.pools : p.role == "data-pipelines" && p.enabled]) || (try(var.installation_facts.inventory_store, null) != null && try(var.installation_facts.outbox_store, null) != null), false)
    error_message = "Enabled Data Pipelines requires explicit inventory_store and outbox_store facts; storage names or prefixes cannot be inferred."
  }
  validation {
    condition = alltrue([for store in [try(var.installation_facts.inventory_store, null), try(var.installation_facts.outbox_store, null)] : store == null ? true : try(
    store.owner_account_id == var.installation_facts.aws_account_id && store.region == var.installation_facts.aws_region && can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", store.bucket)) && can(regex("^[A-Za-z0-9/_.=-]*$", store.prefix)) && length(store.prefix) <= 1024 && !startswith(store.prefix, "/") && !anytrue([for part in split("/", store.prefix) : contains([".", ".."], part)]), false)])
    error_message = "Inventory/outbox stores must be exact S3Store facts in the installation account/region with relative traversal-free prefixes."
  }


  validation {
    condition = !anytrue([for p in var.installation_facts.pools : p.role == "data-pipelines" && p.enabled]) ? true : try(
      alltrue([for store in [var.installation_facts.inventory_store, var.installation_facts.outbox_store] : length(trimsuffix(store.prefix, "/")) > 0 && endswith(store.prefix, "/") && !strcontains(store.prefix, "//")]) &&
      (var.installation_facts.inventory_store.bucket != var.installation_facts.outbox_store.bucket || (
        trimsuffix(var.installation_facts.inventory_store.prefix, "/") != trimsuffix(var.installation_facts.outbox_store.prefix, "/") &&
        !startswith(var.installation_facts.inventory_store.prefix, "${trimsuffix(var.installation_facts.outbox_store.prefix, "/")}/") &&
        !startswith(var.installation_facts.outbox_store.prefix, "${trimsuffix(var.installation_facts.inventory_store.prefix, "/")}/")
      ))
    , false)
    error_message = "Enabled Data Pipelines requires nonempty disjoint inventory/outbox folder prefixes ending in /, without overlapping paths in the same bucket."
  }
  validation {
    condition = try(length(var.installation_facts.exporter.publish_topic_paths) == 0 && alltrue([for p in var.installation_facts.pools :
      alltrue([for topic in p.publish_topic_paths : can(regex("^projects/${var.installation_facts.execution_project_id}/topics/[A-Za-z][A-Za-z0-9._~+%-]{2,254}$", topic))]) &&
      (!(p.enabled && contains(["sampler", "analyzer", "data-pipelines", "inventory-notification"], p.role)) || length(p.publish_topic_paths) > 0)
    ]), false)
    error_message = "Publish topics must be exact execution-project topic paths; enabled producer roles require explicit topics and exporter may not publish."
  }

}
variable "activated" {
  description = "Explicit operator activation only after enrollment and acceptance. False suspends all policies and bootstraps every service at zero."
  type        = bool
  default     = false
}
variable "vpc_id" {
  type = string
}
variable "private_subnet_ids" {
  type = set(string)
  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Supply private subnets in at least two availability zones."
  }
}
variable "create_cluster" {
  type    = bool
  default = true
}
variable "manage_cluster_capacity_association" {
  description = "Explicit ownership of the cluster-wide provider association. Existing shared clusters should leave false and associate externally before activation."
  type        = bool
  default     = true
}
variable "capacity" {
  description = "Per-role owned EC2 capacity; existing provider requires a reviewed per-role reservation/dependency proof. One instance type per owned role gives an enforceable smallest-instance fit."
  type = map(object({
    instance_type     = optional(string)
    ami_id            = optional(string)
    max_instances     = number
    root_volume_gib   = number
    existing_provider = optional(string)
    reservation_proof = optional(object({ review_reference = string, reserved_tasks = number, independent_child_capacity = bool, zero_bootstrap_supported = bool }))
  }))
  default = {}
}
variable "fargate_ephemeral_storage_gib" {
  description = "Total ephemeral storage for each Fargate worker task, including container image layers and scratch."
  type        = number
  default     = 100
  nullable    = false
  validation {
    condition     = var.fargate_ephemeral_storage_gib >= 21 && var.fargate_ephemeral_storage_gib <= 200 && var.fargate_ephemeral_storage_gib == floor(var.fargate_ephemeral_storage_gib)
    error_message = "Fargate ephemeral storage must be an integer from 21 to 200 GiB."
  }
}
variable "egress_cidrs" {
  description = "Approved outbound TLS routes; customer NAT or private routing must reach AWS, Google, approved vendors and Relyance."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}
variable "provision_redis" {
  type    = bool
  default = true
}
variable "ecs_redis" {
  description = "Opt-in singleton Redis service on Fargate, backed by an encrypted EFS volume. Omit to retain ElastiCache or the supplied endpoint."
  type = object({
    image_digest        = string
    dns_namespace       = string
    tls_secret_arn      = string
    secret_kms_key_arns = optional(set(string), [])
    cpu_units           = optional(number, 1024)
    memory_mib          = optional(number, 2048)
    start               = optional(bool, false)
  })
  default = null
  validation {
    condition = var.ecs_redis == null || try(
      can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9][a-z0-9_./-]*@sha256:[a-f0-9]{64}$", var.ecs_redis.image_digest)) &&
      length(var.ecs_redis.dns_namespace) <= 247 && length(split(".", var.ecs_redis.dns_namespace)) >= 2 &&
      alltrue([for label in split(".", var.ecs_redis.dns_namespace) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label))]),
      false
    )
    error_message = "ECS Redis requires a digest-pinned ECR image and a valid private DNS namespace."
  }
}
variable "existing_redis_verified" {
  description = "Operator verified existing endpoint: provisioned nonclustered Redis, TLS/auth, persistent Multi-AZ replica, exact installation host/secret and exporter read-only ACL."
  type        = bool
  default     = false
}
variable "redis_node_type" {
  type    = string
  default = "cache.t3.small"
}
variable "redis_worker_user_id" {
  type    = string
  default = "inhost-workers"
}
variable "redis_exporter_user_id" {
  type    = string
  default = "inhost-exporter"
}
variable "exporter_redis_secret_arn" {
  description = "Separate Secrets Manager reference containing exporter read-only Redis username/password; never the worker credential."
  type        = string
}
variable "redis_auth_secret_version" {
  description = "Nonsecret version number to rotate referenced Redis credentials during reviewed apply."
  type        = number
  default     = 1
}
variable "source_secret_arns" {
  description = "Exact additional per-role source secret references approved by installation registration. Exporter never receives them."
  type        = map(set(string))
  default     = {}
  validation {
    condition     = alltrue(flatten([for role, arns in var.source_secret_arns : [for arn in arns : contains(["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"], role) && can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$", arn))]]))
    error_message = "Source grants require exact secret ARNs and worker roles; exporter source access is forbidden."
  }
}
variable "secret_kms_key_arns" {
  description = "Exact customer CMK ARNs for runtime secret decryption, independently per workload including exporter."
  type        = map(set(string))
  default     = {}
  validation {
    condition     = alltrue(flatten([for role, arns in var.secret_kms_key_arns : [for arn in arns : contains(["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification", "exporter"], role) && can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", arn))]]))
    error_message = "Runtime secret decryption grants require exact KMS key ARNs and known workload roles."
  }
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "existing_redis_security_group_id" {
  description = "When supplying Redis, exact endpoint security group; authorizes module-owned task ingress/egress rules on that group."
  type        = string
  default     = null
}
variable "runtime_users" {
  description = "Verified UID/GID for each released worker image (default 65532:65532). Images must precreate /scratch with this owner before Docker volume copy-up."
  type        = map(object({ uid = number, gid = number }))
  default     = {}
  validation {
    condition     = alltrue([for u in values(var.runtime_users) : u.uid > 0 && u.gid > 0 && u.uid == floor(u.uid) && u.gid == floor(u.gid)])
    error_message = "Workers must run with explicit positive nonroot numeric UIDs/GIDs."
  }
}
variable "application_environment" {
  description = "Per-role existing InHost app configuration: nonsecret API origins, GAI_NOTIFICATION_TENANT tenant slug and released application settings. Credentials belong in referenced secrets; runtime authority fields cannot be overridden."
  type        = map(map(string))
  default     = {}
  validation {
    condition = alltrue(flatten([for role, env in var.application_environment : [for name, value in env :
      contains(["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"], role) && can(regex("^[A-Z][A-Z0-9_]*$", name)) &&
      length(regexall("^(INHOST_|AWS_|REDIS_|GOOGLE_|PUBSUB_|S3_|WORK_STORE|FINDINGS_|INVENTORY_|OUTBOX_|GCP_PROJECT_ID$|TENANT_BUCKET_PATH$|TOPIC_NAME$|WORKER_POOL$|DEPLOYMENT_ID$|EXECUTION_PROJECT_ID$|ROUTE_REVISION$|RUN_JOB_MODE$|GAI_DISTRIBUTED_RUN_JOB_MODE$|GAI_PUBSUB_TOPIC_ID$|RUNTIME_MODE$|RUNTIME_CLOUD$|IS_SHARED_ENV$|IDENTITY_SERVICE_WORKLOAD_AUDIENCE$|TMPDIR$)", name)) == 0 &&
      (!startswith(name, "DP_") || (role == "data-pipelines" && contains(["DP_TENANT", "DP_AWS_QUERY_REGIONS"], name))) &&
      (name != "DP_AWS_QUERY_REGIONS" || (
        length(split(",", value)) == length(distinct(split(",", value))) &&
        alltrue([for region in split(",", value) : can(regex("^[a-z]{2}(?:-[a-z]+)+-[0-9]+$", region))])
      )) &&
      length(regexall("PASSWORD|SECRET|TOKEN|CREDENTIAL|PRIVATE_KEY|API_KEY|ACCESS_KEY", name)) == 0 &&
      length(regexall("-----BEGIN|eyJ[A-Za-z0-9_-]+\\.eyJ|://[^/@[:space:]]+:[^/@[:space:]]+@", value)) == 0
    ]]))
    error_message = "Application environment must be nonsecret per-role uppercase settings and cannot override platform, route, credential, Redis, Google, AWS or job-mode authority."
  }
}
variable "store_kms_key_arns" {
  description = "Exact reviewed SSE-KMS keys for existing work/findings/inventory/outbox stores. Key/bucket owner policies must also admit worker roles. Exporter receives no store-key grant."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.store_kms_key_arns : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[A-Za-z0-9-]+$", arn))])
    error_message = "Store encryption keys must be exact KMS key ARNs without wildcards."
  }
}
variable "source_role_arns" {
  description = "Exact reviewed commercial AWS source role ARNs each worker may assume, including cross-account roles and IAM paths. Source trust/ExternalId contracts remain independently owned; exporter receives no AssumeRole grant."
  type        = map(set(string))
  default     = {}
  validation {
    condition     = alltrue([for role in keys(var.source_role_arns) : contains(["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"], role)]) && alltrue(flatten([for arns in values(var.source_role_arns) : [for arn in arns : length(arn) <= 2048 && can(regex("^arn:aws:iam::[0-9]{12}:role/([A-Za-z0-9_+=,.@-]+/)*[A-Za-z0-9_+=,.@-]{1,64}$", arn))]]))
    error_message = "Source-role grants require known worker keys and exact commercial IAM role ARNs without wildcards; exporter role assumption is forbidden."
  }
}

variable "enable_versioned_inventory_result_cleanup" {
  description = "Explicitly authorize permanent deletion of captured non-null versions of owned temporary Data Pipelines result batches, after their commit/publication barrier. No source objects or durable journals are covered."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_versioned_inventory_result_cleanup || anytrue([for pool in try(var.installation_facts.pools, []) : pool.role == "data-pipelines" && pool.enabled])
    error_message = "Versioned inventory result cleanup requires an enabled Data Pipelines pool."
  }
}


variable "pubsub_global_zero_subscriptions" {
  description = "Default-empty exact enabled Pub/Sub subscriptions whose missing/stale regional coverage may be confirmed by a fresh explicit subscription-wide zero. Errors, positive global backlog and incomplete reads remain unknown. Exporter only; shared worker facts are unchanged."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([for path in var.pubsub_global_zero_subscriptions : contains([
      for pool in var.installation_facts.pools : try(pool.source.subscription_path, "")
      if pool.enabled && pool.source.kind == "pubsub"
    ], path)])
    error_message = "Global zero confirmation requires exact enabled installation Pub/Sub subscription paths."
  }
}
