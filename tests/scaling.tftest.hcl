# Terraform 1.13 cannot mock ephemeral types. This unused alias has no
# instances in these existing-Redis tests; every infrastructure provider is mocked.
provider "aws" {
  alias                       = "secrets"
  region                      = "us-west-2"
  access_key                  = "synthetic-test-only"
  secret_key                  = "synthetic-test-only"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}
mock_provider "aws" {
  mock_data "aws_ami" { defaults = { id = "ami-12345678", architecture = "x86_64", root_device_type = "ebs", root_device_name = "/dev/xvda" } }

  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/ecs-fixture-ecs-execution" } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-12345678", latest_version = 1 } }
  mock_resource "aws_autoscaling_group" { defaults = { arn = "arn:aws:autoscaling:us-west-2:111111111111:autoScalingGroup:synthetic:autoScalingGroupName/ecs-fixture" } }
  mock_resource "aws_ecs_capacity_provider" { defaults = { arn = "arn:aws:ecs:us-west-2:111111111111:capacity-provider/ecs-fixture" } }
  mock_resource "aws_ecs_task_definition" { defaults = { arn = "arn:aws:ecs:us-west-2:111111111111:task-definition/ecs-fixture:1" } }
  mock_resource "aws_ecs_cluster" { defaults = { id = "arn:aws:ecs:us-west-2:111111111111:cluster/ecs-fixture" } }
  mock_resource "aws_security_group" { defaults = { id = "sg-12345678" } }
  mock_resource "aws_appautoscaling_policy" { defaults = { arn = "arn:aws:autoscaling:us-west-2:111111111111:scalingPolicy:synthetic-test" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/relyance/inhost/ecs-fixture" } }

  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-12345678", map_public_ip_on_launch = false } }

  mock_data "aws_caller_identity" { defaults = { account_id = "111111111111" } }
  mock_data "aws_region" { defaults = { region = "us-west-2" } }
  mock_data "aws_ec2_instance_type" { defaults = { default_vcpus = 16, memory_size = 131072, maximum_network_interfaces = 8, supported_architectures = ["x86_64"] } }
}
override_data {
  target = data.aws_subnet.private["subnet-12345678"]
  values = { vpc_id = "vpc-12345678", availability_zone = "us-west-2a", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.private["subnet-87654321"]
  values = { vpc_id = "vpc-12345678", availability_zone = "us-west-2b", map_public_ip_on_launch = false }
}
variables {
  application_environment = merge({ for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker"] : role => { GAI_NOTIFICATION_TENANT = "synthetic-tenant" } }, { "data-pipelines" = { DP_TENANT = "synthetic-tenant" } })

  existing_redis_security_group_id = "sg-12345678"
  exporter_redis_secret_arn        = "arn:aws:secretsmanager:us-west-2:111111111111:secret:ecs-fixture-exporter-AbCdEf"
  installation_facts               = jsondecode(file("tests/fixtures/installation.json"))
  vpc_id                           = "vpc-12345678"
  private_subnet_ids               = ["subnet-12345678", "subnet-87654321"]
  provision_redis                  = false
  existing_redis_verified          = true
  capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
    instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 3, root_volume_gib = 200
  } }
}
run "four_safe_policies" {
  command = plan
  assert {
    condition     = length(aws_appautoscaling_policy.out) == 5 && length(aws_appautoscaling_policy.step) == 15
    error_message = "Each pool requires exactly four scaling policies."
  }
  assert {
    condition     = alltrue([for p in aws_appautoscaling_policy.out : p.target_tracking_scaling_policy_configuration[0].target_value == 1 && p.target_tracking_scaling_policy_configuration[0].disable_scale_in && p.target_tracking_scaling_policy_configuration[0].scale_out_cooldown == 60])
    error_message = "Target tracking must scale out only at 1.0 with cooldown 60."
  }
  assert {
    condition     = alltrue([for p in aws_appautoscaling_policy.step : p.step_scaling_policy_configuration[0].adjustment_type == "ChangeInCapacity" && one(p.step_scaling_policy_configuration[0].step_adjustment).scaling_adjustment == 1 if endswith(p.name, "bootstrap")])
    error_message = "Delayed bootstrap must add one, never shrink to exact one."
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.step : one([for q in a.metric_query : q.expression if q.id == "gate"]) == "FILL(e,0) * FILL(v,0) * FILL(h,0)" && a.treat_missing_data == "notBreaching"])
    error_message = "Old positive datapoints must not authorize scale-in after exporter death."
  }
  assert {
    condition     = alltrue([for t in aws_appautoscaling_target.worker : t.min_capacity == 0 && t.suspended_state[0].dynamic_scaling_in_suspended && t.suspended_state[0].dynamic_scaling_out_suspended && t.suspended_state[0].scheduled_scaling_suspended])
    error_message = "Held installation suspends every scaling direction."
  }
}
run "precise_step_windows_and_health" {
  command = plan
  variables { activated = true }
  assert {
    condition     = alltrue([for k, a in aws_cloudwatch_metric_alarm.step : a.evaluation_periods == (endswith(k, "bootstrap") ? 1 : endswith(k, "shrink") ? 5 : 2) && a.datapoints_to_alarm == a.evaluation_periods && a.actions_enabled && alltrue([for q in a.metric_query : one(q.metric).stat == "Minimum" && one(q.metric).period == 60 if q.id != "gate"])])
    error_message = "Bootstrap1/shrink5/idle2 consecutive 60s Minimum windows, gated by all health series, are mandatory."
  }
  assert {
    condition     = alltrue([for p in aws_appautoscaling_policy.step : p.step_scaling_policy_configuration[0].cooldown == 120 && p.step_scaling_policy_configuration[0].metric_aggregation_type == "Minimum" && (endswith(p.name, "shrink") ? p.step_scaling_policy_configuration[0].adjustment_type == "ChangeInCapacity" && one(p.step_scaling_policy_configuration[0].step_adjustment).scaling_adjustment == -1 : endswith(p.name, "idle") ? p.step_scaling_policy_configuration[0].adjustment_type == "ExactCapacity" && one(p.step_scaling_policy_configuration[0].step_adjustment).scaling_adjustment == 0 : true)])
    error_message = "Shrink removes one and idle sets exact0, each cooldown120."
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.heartbeat : a.treat_missing_data == "breaching" && a.statistic == "Minimum"]) && alltrue([for p in aws_appautoscaling_policy.out : p.target_tracking_scaling_policy_configuration[0].customized_metric_specification[0].statistic == "Maximum"])
    error_message = "Missing heartbeat fails health; repeated demand gauges never sum."
  }
}
run "old_positive_cannot_authorize_missing_current_periods" {
  command = plan
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.step : one([for q in a.metric_query : q.expression if q.id == "gate"]) == "FILL(e,0) * FILL(v,0) * FILL(h,0)"]) && alltrue([for p in jsondecode(file("tests/fixtures/old-positive-then-exporter-crash.json")).current_periods : coalesce(p.eligibility, 0) * coalesce(p.snapshot, 0) * coalesce(p.heartbeat, 0) == 0])
    error_message = "A prior positive sample cannot authorize new scale-in periods when current eligibility, snapshot or exporter heartbeat is missing. Native CloudWatch backfill still requires isolated acceptance."
  }
}
