locals {
  steps = { for item in flatten([for role, p in local.pools : [
    for kind, settings in {
      bootstrap = { metric = "CanBootstrap", periods = 1, adjustment_type = "ChangeInCapacity", adjustment = 1 }
      shrink    = { metric = "CanShrink", periods = 5, adjustment_type = "ChangeInCapacity", adjustment = -1 }
      idle      = { metric = "CanStop", periods = 2, adjustment_type = "ExactCapacity", adjustment = 0 }
    } : merge(settings, { role = role, kind = kind })
  ]]) : "${item.role}-${item.kind}" => item }
}
resource "aws_appautoscaling_target" "worker" {
  for_each           = local.pools
  max_capacity       = each.value.max_tasks
  min_capacity       = 0
  resource_id        = "service/${local.cluster_name}/${each.value.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
  suspended_state {
    dynamic_scaling_in_suspended  = !var.activated
    dynamic_scaling_out_suspended = !var.activated
    scheduled_scaling_suspended   = !var.activated
  }
  depends_on = [aws_ecs_service.worker]
}
resource "aws_appautoscaling_policy" "out" {
  for_each           = local.pools
  name               = "${local.name}-${each.key}-out"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker[each.key].resource_id
  scalable_dimension = aws_appautoscaling_target.worker[each.key].scalable_dimension
  service_namespace  = "ecs"
  target_tracking_scaling_policy_configuration {
    target_value       = 1.0
    disable_scale_in   = true
    scale_out_cooldown = 60
    customized_metric_specification {
      namespace   = "Relyance/InHost"
      metric_name = "DemandPerTask"
      statistic   = "Maximum"
      dimensions {
        name  = "DeploymentId"
        value = local.name
      }
      dimensions {
        name  = "WorkerRole"
        value = each.key
      }
    }
  }
}
resource "aws_appautoscaling_policy" "step" {
  for_each           = local.steps
  name               = "${local.name}-${each.key}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.worker[each.value.role].resource_id
  scalable_dimension = aws_appautoscaling_target.worker[each.value.role].scalable_dimension
  service_namespace  = "ecs"
  step_scaling_policy_configuration {
    adjustment_type         = each.value.adjustment_type
    cooldown                = 120
    metric_aggregation_type = "Minimum"
    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = each.value.adjustment
    }
  }
}
resource "aws_cloudwatch_metric_alarm" "step" {
  for_each            = local.steps
  alarm_name          = "${local.name}-${each.key}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = 1
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.activated
  alarm_actions       = [aws_appautoscaling_policy.step[each.key].arn]
  metric_query {
    id          = "gate"
    expression  = "FILL(e,0) * FILL(v,0) * FILL(h,0)"
    label       = "Current complete snapshot permits ${each.value.kind}"
    return_data = true
  }
  dynamic "metric_query" {
    for_each = { e = each.value.metric, v = "SnapshotValid", h = "ExporterHeartbeat" }
    content {
      id          = metric_query.key
      return_data = false
      metric {
        namespace   = "Relyance/InHost"
        metric_name = metric_query.value
        period      = 60
        stat        = "Minimum"
        dimensions  = { DeploymentId = local.name, WorkerRole = each.value.role }
      }
    }
  }
  tags = local.tags
}
