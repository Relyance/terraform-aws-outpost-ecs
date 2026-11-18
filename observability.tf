resource "aws_cloudwatch_log_group" "main" {
  name              = "/relyance/inhost/${local.name}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  for_each            = local.pools
  alarm_name          = "${local.name}-${each.key}-exporter-heartbeat"
  namespace           = "Relyance/InHost"
  metric_name         = "ExporterHeartbeat"
  dimensions          = { DeploymentId = local.name, WorkerRole = each.key }
  period              = 60
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 2
  treat_missing_data  = "breaching"
  actions_enabled     = false
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "snapshot" {
  for_each            = local.pools
  alarm_name          = "${local.name}-${each.key}-snapshot-invalid"
  namespace           = "Relyance/InHost"
  metric_name         = "SnapshotValid"
  dimensions          = { DeploymentId = local.name, WorkerRole = each.key }
  period              = 60
  statistic           = "Minimum"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 2
  treat_missing_data  = "breaching"
  actions_enabled     = false
  tags                = local.tags
}
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-inhost"
  dashboard_body = jsonencode({ widgets = [for role, p in local.pools : {
    type       = "metric", width = 12, height = 6,
    properties = { title = role, region = local.facts.aws_region, period = 60, stat = "Maximum", metrics = [for metric in ["OutstandingWork", "ActiveWork", "RunningTasks", "PendingTasks", "DemandPerTask", "SnapshotValid", "SourceAgeSeconds", "ExporterHeartbeat"] : ["Relyance/InHost", metric, "DeploymentId", local.name, "WorkerRole", role]] }
  }] })
}
