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
run "exporter_read_only" {
  command = plan
  assert {
    condition     = !strcontains(aws_iam_role_policy.exporter.policy, "ecs:RunTask") && !strcontains(aws_iam_role_policy.exporter.policy, "ecs:Update") && !strcontains(aws_iam_role_policy.exporter.policy, "s3:")
    error_message = "Exporter cannot start, resize, protect worker tasks or read source storage."
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.exporter.policy, "sts:GetWebIdentityToken") && strcontains(aws_iam_role_policy.exporter.policy, "cloudwatch:namespace")
    error_message = "Exporter needs scoped short-lived federation and namespace-limited publishing."
  }
}
run "execution_pull_scope" {
  command = plan
  assert {
    condition     = length(local.ecr_repositories) == 6 && contains(local.ecr_repositories, "arn:aws:ecr:us-west-2:111111111111:repository/fixture/sampler")
    error_message = "Image pull permission must follow exact ECR repositories, account and registry region."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "secretsmanager:") && alltrue([for p in aws_iam_role_policy.worker : !strcontains(p.policy, "ecs:RunTask") && !strcontains(p.policy, "ecs:UpdateService")])
    error_message = "Image startup cannot read application secrets and workers cannot launch/resize services."
  }
}
run "route_mismatch_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { route_revision = 2 })
  }
  expect_failures = [var.installation_facts]
}
run "mutable_image_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { exporter = merge(jsondecode(file("tests/fixtures/installation.json")).exporter, { image_digest = "public.ecr.aws/fixture/exporter:latest" }) })
  }
  expect_failures = [var.installation_facts]
}
run "duplicate_services_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { service_name = "duplicate" })] })
  }
  expect_failures = [var.installation_facts]
}
run "reserved_environment_rejected" {
  command = plan
  variables { application_environment = { sampler = { RUN_JOB_MODE = "false" } } }
  expect_failures = [var.application_environment]
}
run "inline_credential_environment_rejected" {
  command = plan
  variables { application_environment = { sampler = { API_ORIGIN = "https://synthetic-user:synthetic-password@example.invalid" } } }
  expect_failures = [var.application_environment]
}
run "cluster_account_mismatch_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { ecs_cluster_arn = "arn:aws:ecs:us-west-2:222222222222:cluster/ecs-fixture" })
  }
  expect_failures = [var.installation_facts]
}
run "activation_requires_registered_tenant_slug" {
  command = plan
  variables { activated = true }
  expect_failures = [terraform_data.contract]
}
run "wildcard_source_secret_rejected" {
  command = plan
  variables { source_secret_arns = { sampler = ["*"] } }
  expect_failures = [var.source_secret_arns]
}
run "exporter_metadata_scope" {
  command = plan
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.exporter.policy).Statement : s if contains(s.Action, "ecs:ListTasks")]).Condition.ArnEquals["ecs:cluster"] == local.cluster_arn && one([for s in jsondecode(aws_iam_role_policy.exporter.policy).Statement : s if contains(s.Action, "ecs:DescribeTasks")]).Condition.StringEquals["aws:ResourceTag/DeploymentId"] == local.name && alltrue([for s in aws_ecs_service.worker : s.propagate_tags == "SERVICE" && s.enable_ecs_managed_tags])
    error_message = "Exporter metadata reads must retain exact cluster/deployment scope and worker task tags."
  }
}
run "store_kms_only_workers" {
  command = plan
  variables { store_kms_key_arns = ["arn:aws:kms:us-west-2:111111111111:key/synthetic-store-key"] }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.worker : strcontains(p.policy, "kms:GenerateDataKey") && strcontains(p.policy, "kms:EncryptionContext:aws:s3:arn")]) && !strcontains(aws_iam_role_policy.exporter.policy, "kms:GenerateDataKey")
    error_message = "SSE-KMS write grants belong only to workers and exact S3 store encryption contexts."
  }
}
run "wildcard_redis_reference_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { redis = merge(jsondecode(file("tests/fixtures/installation.json")).redis, { secret_arn = "arn:aws:secretsmanager:us-west-2:111111111111:secret:*" }) })
  }
  expect_failures = [var.installation_facts]
}
run "cross_account_source_role_allowlist" {
  command = plan
  variables {
    source_role_arns = { "data-pipelines" = ["arn:aws:iam::222222222222:role/sources/ReviewedInventoryReader"] }
  }
  assert {
    condition     = anytrue([for s in jsondecode(aws_iam_role_policy.worker["data-pipelines"].policy).Statement : toset(s.Resource) == toset(["arn:aws:iam::222222222222:role/sources/ReviewedInventoryReader"]) if contains(s.Action, "sts:AssumeRole")]) && !strcontains(aws_iam_role_policy.worker["sampler"].policy, "sts:AssumeRole") && !strcontains(aws_iam_role_policy.exporter.policy, "sts:AssumeRole")
    error_message = "Only the approved worker may assume the exact reviewed cross-account source role."
  }
}
run "wildcard_source_role_rejected" {
  command = plan
  variables { source_role_arns = { "data-pipelines" = ["arn:aws:iam::222222222222:role/*"] } }
  expect_failures = [var.source_role_arns]
}
run "exporter_source_role_rejected" {
  command = plan
  variables { source_role_arns = { exporter = ["arn:aws:iam::222222222222:role/ReviewedInventoryReader"] } }
  expect_failures = [var.source_role_arns]
}
run "malformed_source_role_rejected" {
  command = plan
  variables { source_role_arns = { "data-pipelines" = ["arn:aws-cn:iam::222222222222:role/ReviewedInventoryReader"] } }
  expect_failures = [var.source_role_arns]
}
run "unrecognized_worker_source_role_rejected" {
  command = plan
  variables { source_role_arns = { "arbitrary-worker" = ["arn:aws:iam::222222222222:role/ReviewedInventoryReader"] } }
  expect_failures = [var.source_role_arns]
}
run "empty_exporter_source_role_entry_rejected" {
  command = plan
  variables { source_role_arns = { exporter = [] } }
  expect_failures = [var.source_role_arns]
}
run "empty_role_name_rejected" {
  command = plan
  variables { source_role_arns = { "data-pipelines" = ["arn:aws:iam::222222222222:role/"] } }
  expect_failures = [var.source_role_arns]
}

run "reserved_exporter_service_name_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, {
        service_name = p.role == "sampler" ? "ecs-fixture-exporter" : p.service_name
      })]
    })
  }
  expect_failures = [var.installation_facts]
}
