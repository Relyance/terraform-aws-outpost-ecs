# Credentials are provisioned outside this module in Secrets Manager. Ephemeral reads
# feed only write-only ElastiCache arguments and are never persisted in plans/state.
ephemeral "aws_secretsmanager_secret_version" "worker" {
  provider  = aws.secrets
  count     = var.provision_redis ? 1 : 0
  secret_id = local.facts.redis.secret_arn
}
ephemeral "aws_secretsmanager_secret_version" "exporter" {
  provider  = aws.secrets
  count     = var.provision_redis ? 1 : 0
  secret_id = var.exporter_redis_secret_arn
}
resource "aws_elasticache_user" "worker" {
  count     = var.provision_redis ? 1 : 0
  user_id   = "${local.name}-workers"
  user_name = var.redis_worker_user_id
  engine    = "redis"
  # One dedicated installation already shares this worker user across all keys/DBs.
  # Celery result and Kombu DB/exchange/event channels have no common configured
  # prefix. Grant installation-wide channels; exporter receives no channel grant.
  access_string        = "on ~* &* +@all -@admin -@dangerous +eval +evalsha -script +script|load"
  passwords_wo         = jsondecode(ephemeral.aws_secretsmanager_secret_version.worker[0].secret_string).password
  passwords_wo_version = var.redis_auth_secret_version
  tags                 = local.tags
}
resource "aws_elasticache_user" "exporter" {
  count     = var.provision_redis ? 1 : 0
  user_id   = "${local.name}-exporter"
  user_name = var.redis_exporter_user_id
  engine    = "redis"
  # Counter/registry metadata only. No business pull, ACK, writes, EVAL or secret ACL access.
  access_string        = "on ${join(" ", [for p in values(local.pools) : "~${p.source.queue_name}" if p.source.kind == "redis"])} ~inhost-runtime:v1:${local.name}:* -@all +ping +select +llen +mget"
  passwords_wo         = jsondecode(ephemeral.aws_secretsmanager_secret_version.exporter[0].secret_string).password
  passwords_wo_version = var.redis_auth_secret_version
  tags                 = local.tags
}
resource "aws_elasticache_user" "default" {
  count                = var.provision_redis ? 1 : 0
  user_id              = "${local.name}-default"
  user_name            = "default"
  engine               = "redis"
  access_string        = "off ~* -@all"
  no_password_required = true
  tags                 = local.tags
}
resource "aws_elasticache_user_group" "main" {
  count         = var.provision_redis ? 1 : 0
  engine        = "redis"
  user_group_id = local.name
  user_ids      = [aws_elasticache_user.default[0].user_id, aws_elasticache_user.worker[0].user_id, aws_elasticache_user.exporter[0].user_id]
}
resource "aws_elasticache_subnet_group" "main" {
  count      = var.provision_redis ? 1 : 0
  name       = local.name
  subnet_ids = var.private_subnet_ids
  tags       = local.tags
}
resource "aws_elasticache_replication_group" "main" {
  count                      = var.provision_redis ? 1 : 0
  replication_group_id       = local.name
  description                = "Persistent InHost broker, result and lifecycle state"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.redis_node_type
  port                       = local.facts.redis.port
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  parameter_group_name       = "default.redis7"
  user_group_ids             = [aws_elasticache_user_group.main[0].user_group_id]
  subnet_group_name          = aws_elasticache_subnet_group.main[0].name
  security_group_ids         = [aws_security_group.redis[0].id]
  snapshot_retention_limit   = 7
  final_snapshot_identifier  = "${local.name}-final"
  auto_minor_version_upgrade = true
  tags                       = local.tags
  lifecycle { prevent_destroy = true }
}
