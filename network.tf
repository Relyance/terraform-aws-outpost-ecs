resource "aws_security_group" "task" {
  name_prefix = "${local.name}-task-"
  description = "Private ECS tasks; no inbound worker service ports"
  vpc_id      = var.vpc_id
  tags        = local.tags
}
resource "aws_security_group" "instance" {
  name_prefix = "${local.name}-instance-"
  description = "Private ECS container instances; no inbound access"
  vpc_id      = var.vpc_id
  tags        = local.tags
}
locals {
  redis_security_group_id = var.provision_redis ? aws_security_group.redis[0].id : var.existing_redis_security_group_id
}
resource "aws_security_group" "redis" {
  count       = var.provision_redis ? 1 : 0
  name_prefix = "${local.name}-redis-"
  description = "TLS Redis accessible only from installation task ENIs"
  vpc_id      = var.vpc_id
  tags        = local.tags
}
resource "aws_vpc_security_group_egress_rule" "task_tls" {
  for_each          = var.egress_cidrs
  security_group_id = aws_security_group.task.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_security_group_egress_rule" "instance_tls" {
  for_each          = var.egress_cidrs
  security_group_id = aws_security_group.instance.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
resource "aws_vpc_security_group_egress_rule" "redis" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = local.redis_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.facts.redis.port
  to_port                      = local.facts.redis.port
}
resource "aws_vpc_security_group_ingress_rule" "redis" {
  security_group_id            = local.redis_security_group_id
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = local.facts.redis.port
  to_port                      = local.facts.redis.port
}

data "aws_subnet" "private" {
  for_each = var.private_subnet_ids
  id       = each.value
}
