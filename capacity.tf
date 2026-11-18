data "aws_ec2_instance_type" "worker" {
  for_each      = local.owned
  instance_type = each.value.instance_type
}
data "aws_ami" "worker" {
  for_each = local.owned
  owners   = ["self", "amazon"]
  filter {
    name   = "image-id"
    values = [each.value.ami_id]
  }
}
locals {
  # Reserve 1 vCPU and 1GiB for ECS/OS. awsvpc ENI capacity is an independent bound.
  physical_task_fit  = { for role, c in local.owned : role => min(floor((data.aws_ec2_instance_type.worker[role].default_vcpus * 1024 - 1024) / local.pools[role].cpu_units), floor((data.aws_ec2_instance_type.worker[role].memory_size - 1024) / local.pools[role].memory_mib), data.aws_ec2_instance_type.worker[role].maximum_network_interfaces - 1) }
  tasks_per_instance = { for role, fit in local.physical_task_fit : role => fit >= 1 ? 1 : 0 }
}
resource "aws_launch_template" "worker" {
  for_each               = local.owned
  name_prefix            = "${local.name}-${each.key}-"
  image_id               = each.value.ami_id
  instance_type          = each.value.instance_type
  vpc_security_group_ids = [aws_security_group.instance.id]
  update_default_version = true
  iam_instance_profile { name = aws_iam_instance_profile.worker[each.key].name }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = data.aws_ami.worker[each.key].root_device_name
    ebs {
      volume_size           = each.value.root_volume_gib
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    set -eu
    cat >> /etc/ecs/ecs.config <<'CONFIG'
    ECS_CLUSTER=${local.cluster_name}
    ECS_CONTAINER_STOP_TIMEOUT=600s
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_AWSVPC_BLOCK_IMDS=true
    ECS_RESERVED_MEMORY=1024
    CONFIG
    USERDATA
  )
  tags = local.tags
}
resource "aws_autoscaling_group" "worker" {
  for_each              = local.owned
  name                  = "${local.name}-${each.key}"
  min_size              = 0
  max_size              = each.value.max_instances
  desired_capacity      = 0
  protect_from_scale_in = true
  vpc_zone_identifier   = var.private_subnet_ids
  launch_template {
    id      = aws_launch_template.worker[each.key].id
    version = tostring(aws_launch_template.worker[each.key].latest_version)
  }
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
  lifecycle { ignore_changes = [desired_capacity] }
}
resource "aws_ecs_capacity_provider" "worker" {
  for_each = local.owned
  name     = local.pools[each.key].capacity_provider
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.worker[each.key].arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = each.value.max_instances
      instance_warmup_period    = 120
    }
  }
  tags = local.tags
}
resource "aws_ecs_cluster_capacity_providers" "main" {
  count              = var.manage_cluster_capacity_association ? 1 : 0
  cluster_name       = local.cluster_name
  capacity_providers = concat(["FARGATE"], [for p in aws_ecs_capacity_provider.worker : p.name], [for c in values(local.existing) : c.existing_provider])
  depends_on         = [aws_ecs_cluster.main]
}
