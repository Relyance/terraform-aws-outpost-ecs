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
  mock_data "aws_ec2_instance_type" {
    defaults = { default_vcpus = 16, memory_size = 131072, maximum_network_interfaces = 8, supported_architectures = ["x86_64"] }
  }
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
run "independent_protected_capacity" {
  command = plan
  assert {
    condition     = length(aws_autoscaling_group.worker) == 5 && alltrue([for g in aws_autoscaling_group.worker : g.min_size == 0 && g.protect_from_scale_in])
    error_message = "Every role needs a separate bounded, instance-protected zero-capable ASG."
  }
  assert {
    condition     = alltrue([for p in aws_ecs_capacity_provider.worker : p.auto_scaling_group_provider[0].managed_termination_protection == "ENABLED" && p.auto_scaling_group_provider[0].managed_draining == "ENABLED"])
    error_message = "Provider termination protection and draining are mandatory."
  }
  assert {
    condition     = alltrue([for s in aws_ecs_service.worker : one(s.placement_constraints).type == "distinctInstance"]) && alltrue([for t in aws_launch_template.worker : strcontains(base64decode(t.user_data), "ECS_CONTAINER_STOP_TIMEOUT=600s") && t.block_device_mappings != null])
    error_message = "Owned placement must enforce one task per instance and configure the agent's 600s stop timeout."
  }
}
run "insufficient_capacity_rejected" {
  command = plan
  variables {
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
      instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 1, root_volume_gib = 200
    } }
  }
  expect_failures = [terraform_data.contract]
}
run "unproven_shared_provider_rejected" {
  command = plan
  variables {
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
      existing_provider = "ecs-${role}", max_instances = 3, root_volume_gib = 200
    } }
  }
  expect_failures = [terraform_data.contract]
}
run "small_instance_rejected" {
  command = plan
  override_data {
    target = data.aws_ec2_instance_type.worker["sampler"]
    values = { default_vcpus = 4, memory_size = 8192, maximum_network_interfaces = 3, supported_architectures = ["x86_64"] }
  }
  expect_failures = [terraform_data.contract]
}
run "bounded_asg_must_fit_full_role_maximum" {
  command = plan
  variables {
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
      instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 2, root_volume_gib = 200
    } }
  }
  expect_failures = [terraform_data.contract]
}
run "arm_capacity_rejects_x86_tasks" {
  command = plan
  override_data {
    target = data.aws_ec2_instance_type.worker["sampler"]
    values = { default_vcpus = 16, memory_size = 131072, maximum_network_interfaces = 8, supported_architectures = ["arm64"] }
  }
  expect_failures = [terraform_data.contract]
}
run "reviewed_shared_existing_capacity_can_mix_with_owned_children" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { capacity_provider = contains(["sampler", "analyzer"], p.role) ? "reviewed-shared" : p.capacity_provider })] })
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
      instance_type     = contains(["sampler", "analyzer"], role) ? null : "r6i.4xlarge"
      ami_id            = contains(["sampler", "analyzer"], role) ? null : "ami-12345678"
      max_instances     = 6
      root_volume_gib   = 200
      existing_provider = contains(["sampler", "analyzer"], role) ? "reviewed-shared" : null
      reservation_proof = contains(["sampler", "analyzer"], role) ? { review_reference = "reviewed-role-reservations", reserved_tasks = 3, independent_child_capacity = true, zero_bootstrap_supported = true } : null
    } }
  }
  assert {
    condition     = length(aws_autoscaling_group.worker) == 3 && length(aws_ecs_service.worker) == 5
    error_message = "Explicit reviewed shared coordinator reservations must coexist with separately owned child/DP providers."
  }
}
