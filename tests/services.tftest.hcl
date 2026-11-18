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

  mock_resource "aws_launch_template" { defaults = { id = "lt-12345678", latest_version = 1 } }
  mock_resource "aws_autoscaling_group" { defaults = { arn = "arn:aws:autoscaling:us-west-2:111111111111:autoScalingGroup:synthetic:autoScalingGroupName/ecs-fixture" } }
  mock_resource "aws_ecs_capacity_provider" { defaults = { arn = "arn:aws:ecs:us-west-2:111111111111:capacity-provider/ecs-fixture" } }

  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::111111111111:role/ecs-fixture-ecs-execution" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-west-2:111111111111:log-group:/relyance/inhost/ecs-fixture" } }
  mock_resource "aws_ecs_task_definition" { defaults = { arn = "arn:aws:ecs:us-west-2:111111111111:task-definition/ecs-fixture:1" } }
  mock_resource "aws_ecs_cluster" { defaults = { id = "arn:aws:ecs:us-west-2:111111111111:cluster/ecs-fixture" } }
  mock_resource "aws_security_group" { defaults = { id = "sg-12345678" } }
  mock_resource "aws_appautoscaling_policy" { defaults = { arn = "arn:aws:autoscaling:us-west-2:111111111111:scalingPolicy:synthetic-test" } }

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
  capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
    instance_type = "r6i.4xlarge", ami_id = "ami-12345678", instance_cpu_units = 16384, instance_memory_mib = 131072, max_instances = 3, root_volume_gib = 200
  } }
  existing_redis_verified = true
  provision_redis         = false
}
run "canonical_workload_audiences_for_all_workers" {
  command = plan
  variables {
    installation_facts = jsondecode(file("tests/fixtures/installation-with-notifications.json"))
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"] : role => {
      instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 3, root_volume_gib = 200
    } }
  }
  assert {
    condition = length(aws_ecs_task_definition.worker) == 6 && alltrue([
      for role, task in aws_ecs_task_definition.worker :
      [for entry in jsondecode(task.container_definitions)[0].environment : entry.value if entry.name == "IDENTITY_SERVICE_WORKLOAD_AUDIENCE"] == ["int://identity/workloads/ecs-fixture/${role}"]
    ])
    error_message = "Every enabled worker requires its exact deployment-qualified Identity workload audience."
  }
  assert {
    condition     = alltrue([for entry in jsondecode(aws_ecs_task_definition.exporter.container_definitions)[0].environment : entry.name != "IDENTITY_SERVICE_WORKLOAD_AUDIENCE"]) && alltrue([for service in aws_ecs_service.worker : service.desired_count == 0])
    error_message = "The exporter has no managed application audience, and the installation remains held by default."
  }
}

run "reject_workload_audience_override" {
  command = plan
  variables { application_environment = { sampler = { IDENTITY_SERVICE_WORKLOAD_AUDIENCE = "int://identity/workloads/wrong/sampler" } } }
  expect_failures = [var.application_environment]
}

run "explicit_query_regions_reach_dp_container" {
  command = plan
  variables {
    application_environment = { "data-pipelines" = { DP_AWS_QUERY_REGIONS = "us-east-1" } }
  }
  assert {
    condition     = [for entry in jsondecode(aws_ecs_task_definition.worker["data-pipelines"].container_definitions)[0].environment : entry.value if entry.name == "DP_AWS_QUERY_REGIONS"] == ["us-east-1"]
    error_message = "The existing Data Pipelines runtime must receive its explicit query-region scope."
  }
}

run "expose_dedicated_execution_role_for_registry_onboarding" {
  command = plan
  override_resource {
    target          = aws_iam_role.execution
    override_during = plan
    values          = { arn = "arn:aws:iam::111111111111:role/ecs-fixture-ecs-execution" }
  }
  assert {
    condition     = output.task_execution_role_arn == aws_iam_role.execution.arn && aws_iam_role.execution.name == "ecs-fixture-ecs-execution"
    error_message = "Registry onboarding must identify this installation's dedicated ECS execution role."
  }
}

run "query_regions_remain_unset_by_default" {
  command = plan
  assert {
    condition     = length([for entry in jsondecode(aws_ecs_task_definition.worker["data-pipelines"].container_definitions)[0].environment : entry.name if entry.name == "DP_AWS_QUERY_REGIONS"]) == 0
    error_message = "Existing installations must retain their default region selection."
  }
}

run "reject_query_regions_on_gai_role" {
  command = plan
  variables { application_environment = { sampler = { DP_AWS_QUERY_REGIONS = "us-east-1" } } }
  expect_failures = [var.application_environment]
}

run "reject_empty_query_regions" {
  command = plan
  variables { application_environment = { "data-pipelines" = { DP_AWS_QUERY_REGIONS = "" } } }
  expect_failures = [var.application_environment]
}

run "reject_duplicate_query_regions" {
  command = plan
  variables { application_environment = { "data-pipelines" = { DP_AWS_QUERY_REGIONS = "us-east-1,us-east-1" } } }
  expect_failures = [var.application_environment]
}

run "reject_query_region_whitespace" {
  command = plan
  variables { application_environment = { "data-pipelines" = { DP_AWS_QUERY_REGIONS = "us-east-1, us-west-2" } } }
  expect_failures = [var.application_environment]
}

run "reject_malformed_query_region" {
  command = plan
  variables { application_environment = { "data-pipelines" = { DP_AWS_QUERY_REGIONS = "aws-global" } } }
  expect_failures = [var.application_environment]
}

run "held_services" {
  command = plan
  assert {
    condition     = alltrue([for s in aws_ecs_service.worker : s.desired_count == 0]) && aws_ecs_service.exporter.desired_count == 0
    error_message = "Held workers and exporter must start at zero."
  }
  assert {
    condition     = alltrue([for t in aws_ecs_task_definition.worker : jsondecode(t.container_definitions)[0].entryPoint == ["python", "-m", "inhost_runtime.bootstrap"] && jsondecode(t.container_definitions)[0].stopTimeout == 600])
    error_message = "Workers require the runtime wrapper and 600 second stop timeout."
  }
  assert {
    condition     = alltrue([for t in aws_ecs_task_definition.worker : alltrue([for e in jsondecode(t.container_definitions)[0].environment : e.value == "true" if contains(["RUN_JOB_MODE", "GAI_DISTRIBUTED_RUN_JOB_MODE"], e.name)])])
    error_message = "Both GAI job mode flags must remain true."
  }
  assert {
    condition     = alltrue([for role, r in aws_iam_role.worker : r.name != aws_iam_role.execution.name && aws_ecs_task_definition.worker[role].task_role_arn == local.pools[role].task_role_arn])
    error_message = "Task and execution identities must be separate."
  }
  assert {
    condition     = alltrue([for t in aws_ecs_task_definition.worker : jsondecode(t.container_definitions)[0].user == "65532:65532"])
    error_message = "Default scan UID/GID must match existing DP and GAI nonroot image ownership 65532."
  }
}
run "active_exporter_independent" {
  command = plan
  variables { activated = true }
  assert {
    condition     = aws_ecs_service.exporter.desired_count == 1 && aws_ecs_service.exporter.launch_type == "FARGATE" && alltrue([for s in aws_ecs_service.worker : s.desired_count == 0])
    error_message = "Activation runs one independent exporter while workers wait for native zero-wake."
  }
  assert {
    condition     = alltrue([for s in aws_ecs_service.worker : !one(s.network_configuration).assign_public_ip]) && !one(aws_ecs_service.exporter.network_configuration).assign_public_ip
    error_message = "Every task uses private networking."
  }
}
run "mock_autoscaled_state" {
  command = apply
  variables {
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines"] : role => {
      existing_provider = "ecs-${role}", max_instances = 3, root_volume_gib = 200
      reservation_proof = { review_reference = "synthetic-proof", reserved_tasks = 3, independent_child_capacity = true, zero_bootstrap_supported = true }
    } }
  }
  # Exported by check_replan.py as a synthetic baseline; no AWS calls occur.
  assert {
    condition     = aws_ecs_service.worker["sampler"].desired_count == 0
    error_message = "The synthetic baseline starts held before simulating native autoscaling drift."
  }
}
run "optional_inventory_notification_pool" {
  command = plan
  variables {
    installation_facts = jsondecode(file("tests/fixtures/installation-with-notifications.json"))
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"] : role => {
      instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 3, root_volume_gib = 200
    } }
  }
  assert {
    condition     = length(aws_ecs_service.worker) == 6 && jsondecode(aws_ecs_task_definition.worker["inventory-notification"].container_definitions)[0].user == "65532:65532" && jsondecode(aws_ecs_task_definition.worker["inventory-notification"].container_definitions)[0].command == ["inventory-notification"] && one([for e in jsondecode(aws_ecs_task_definition.worker["inventory-notification"].container_definitions)[0].environment : e.value if e.name == "GAI_PUBSUB_TOPIC_ID"]) == "data-pipelines-notification-gai"
    error_message = "Inventory notification requires an independent one-shot Pub/Sub pool and exact notification topic."
  }
}
run "inventory_notification_requires_child_capacity" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation-with-notifications.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation-with-notifications.json")).pools : merge(p, { enabled = !contains(["sampler", "sampler-worker"], p.role) })] })
    capacity = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker", "data-pipelines", "inventory-notification"] : role => {
      instance_type = "r6i.4xlarge", ami_id = "ami-12345678", max_instances = 3, root_volume_gib = 200
    } }
  }
  expect_failures = [terraform_data.contract]
}

run "explicit_worker_uid_override" {
  command = plan
  variables { runtime_users = { sampler = { uid = 4242, gid = 4243 } } }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.worker["sampler"].container_definitions)[0].user == "4242:4243" && jsondecode(aws_ecs_task_definition.exporter.container_definitions)[0].user == "10001:10001"
    error_message = "A verified per-role UID/GID override must be honored without changing exporter identity."
  }
}

run "global_zero_confirmation_default_off" {
  command = plan
  assert {
    condition     = alltrue([for e in jsondecode(aws_ecs_task_definition.exporter.container_definitions)[0].environment : e.name != "INHOST_PUBSUB_GLOBAL_ZERO_SUBSCRIPTIONS_JSON"])
    error_message = "Subscription-wide zero confirmation must require explicit opt-in."
  }
}
run "global_zero_confirmation_exporter_only" {
  command = plan
  variables { pubsub_global_zero_subscriptions = ["projects/ecs-fixture/subscriptions/ecs-sampler"] }
  assert {
    condition     = jsondecode(one([for e in jsondecode(aws_ecs_task_definition.exporter.container_definitions)[0].environment : e.value if e.name == "INHOST_PUBSUB_GLOBAL_ZERO_SUBSCRIPTIONS_JSON"])) == ["projects/ecs-fixture/subscriptions/ecs-sampler"] && alltrue([for t in aws_ecs_task_definition.worker : alltrue([for e in jsondecode(t.container_definitions)[0].environment : e.name != "INHOST_PUBSUB_GLOBAL_ZERO_SUBSCRIPTIONS_JSON"])])
    error_message = "Only exporter may receive the exact enabled subscription allowlist; worker facts must remain compatible."
  }
}
run "global_zero_foreign_subscription_rejected" {
  command = plan
  variables { pubsub_global_zero_subscriptions = ["projects/other-project/subscriptions/ecs-sampler"] }
  expect_failures = [var.pubsub_global_zero_subscriptions]
}

run "fargate_workers_use_existing_runtime_contract" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation-with-notifications.json")), {
      pools = [for pool in jsondecode(file("tests/fixtures/installation-with-notifications.json")).pools : merge(pool, {
        capacity_provider = "FARGATE"
        cpu_units         = 8192
        memory_mib        = 49152
        scratch_gib       = 40
      })]
    })
    capacity      = {}
    runtime_users = { sampler = { uid = 4242, gid = 4243 } }
  }
  assert {
    condition = (
      length(aws_launch_template.worker) == 0 && length(aws_autoscaling_group.worker) == 0 &&
      length(aws_ecs_capacity_provider.worker) == 0 &&
      toset(aws_ecs_cluster_capacity_providers.main[0].capacity_providers) == toset(["FARGATE"])
    )
    error_message = "Fargate must associate the built-in provider without an EC2 capacity plan."
  }
  assert {
    condition = alltrue([for role, task in aws_ecs_task_definition.worker :
      toset(task.requires_compatibilities) == toset(["FARGATE"]) &&
      one(task.ephemeral_storage).size_in_gib == 100 &&
      length(one(task.volume).docker_volume_configuration) == 0 &&
      aws_ecs_service.worker[role].platform_version == "1.4.0" &&
      one(aws_ecs_service.worker[role].capacity_provider_strategy).capacity_provider == "FARGATE" &&
      length(aws_ecs_service.worker[role].ordered_placement_strategy) == 0 &&
      !one(aws_ecs_service.worker[role].network_configuration).assign_public_ip
    ])
    error_message = "Fargate services must use private networking, native ephemeral storage and no EC2 placement settings."
  }
  assert {
    condition = alltrue([for role, task in aws_ecs_task_definition.worker :
      jsondecode(task.container_definitions)[0].command == [role] &&
      jsondecode(task.container_definitions)[0].stopTimeout == 120 &&
      one([for env in jsondecode(task.container_definitions)[0].environment : env.value if env.name == "INHOST_DRAIN_BUDGET_SECONDS"]) == "90" &&
      one(jsondecode(task.container_definitions)[0].dependsOn).condition == "SUCCESS" &&
      jsondecode(task.container_definitions)[1].name == "scratch-init" &&
      !jsondecode(task.container_definitions)[1].essential &&
      jsondecode(task.container_definitions)[1].image == local.pools[role].image_digest
    ])
    error_message = "Run the same role from the pinned image after scratch initialization with the Fargate drain budget."
  }
  assert {
    condition = (
      jsondecode(aws_ecs_task_definition.worker["data-pipelines"].container_definitions)[0].entryPoint[0] == "/app/.venv/bin/python" &&
      jsondecode(aws_ecs_task_definition.worker["sampler"].container_definitions)[0].user == "4242:4243" &&
      slice(jsondecode(aws_ecs_task_definition.worker["sampler"].container_definitions)[1].command, 1, 3) == ["4242", "4243"]
    )
    error_message = "Use the Data Pipelines interpreter and initialize scratch for the configured worker UID and GID."
  }
}

run "reject_invalid_fargate_memory" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      pools = [for pool in jsondecode(file("tests/fixtures/installation.json")).pools : merge(pool, {
        capacity_provider = "FARGATE"
        cpu_units         = 8192
        memory_mib        = pool.role == "sampler" ? 49153 : 49152
        scratch_gib       = 40
      })]
    })
    capacity = {}
  }
  expect_failures = [terraform_data.contract]
}
