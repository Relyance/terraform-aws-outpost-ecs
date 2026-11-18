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
run "dp_missing_inventory_store_rejected" {
  command = plan
  variables {
    installation_facts = { for name, value in jsondecode(file("tests/fixtures/installation.json")) : name => value if name != "inventory_store" }
  }
  expect_failures = [var.installation_facts]
}
run "dp_missing_outbox_store_rejected" {
  command = plan
  variables {
    installation_facts = { for name, value in jsondecode(file("tests/fixtures/installation.json")) : name => value if name != "outbox_store" }
  }
  expect_failures = [var.installation_facts]
}
run "dp_exact_inventory_outbox_s3_and_kms_grants" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      inventory_store = { bucket = "custom-catalogue", prefix = "catalogue/explicit/", region = "us-west-2", owner_account_id = "111111111111" }
      outbox_store    = { bucket = "custom-journals", prefix = "journals/explicit/", region = "us-west-2", owner_account_id = "111111111111" }
    })
    store_kms_key_arns = ["arn:aws:kms:us-west-2:111111111111:key/synthetic-store-key"]
  }
  assert {
    condition     = alltrue([for p in aws_iam_role_policy.worker : contains(one([for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:PutObject")]), "arn:aws:s3:::custom-catalogue/catalogue/explicit/*") && contains(one([for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:PutObject")]), "arn:aws:s3:::custom-journals/journals/explicit/*") && contains(one([for s in jsondecode(p.policy).Statement : s.Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] if contains(s.Action, "kms:GenerateDataKey")]), "arn:aws:s3:::custom-journals/journals/explicit/*")]) && !strcontains(aws_iam_role_policy.exporter.policy, "custom-catalogue") && !strcontains(aws_iam_role_policy.exporter.policy, "custom-journals")
    error_message = "Worker S3 and SSE-KMS grants must follow exact explicit inventory/outbox stores without exporter access."
  }
}
run "wrong_inventory_account_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { inventory_store = { bucket = "custom-catalogue", prefix = "inventory/", region = "us-west-2", owner_account_id = "222222222222" } })
  }
  expect_failures = [var.installation_facts]
}
run "wrong_outbox_region_rejected" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { outbox_store = { bucket = "custom-journals", prefix = "outbox/", region = "us-east-1", owner_account_id = "111111111111" } })
  }
  expect_failures = [var.installation_facts]
}
run "non_dp_stores_optional" {
  command = plan
  variables {
    installation_facts = merge({ for name, value in jsondecode(file("tests/fixtures/installation.json")) : name => value if !contains(["inventory_store", "outbox_store"], name) }, { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { enabled = p.role != "data-pipelines" })] })
  }
  assert {
    condition     = !contains(keys(aws_ecs_service.worker), "data-pipelines")
    error_message = "Non-DP installations must retain compatibility without inventory/outbox facts."
  }
}
run "dp_disjoint_stores_required" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      inventory_store = { bucket = "shared-catalogue", prefix = "inventory/", region = "us-west-2", owner_account_id = "111111111111" }
      outbox_store    = { bucket = "shared-catalogue", prefix = "inventory/outbox/", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  expect_failures = [var.installation_facts]
}
run "dp_nonempty_prefixes_required" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { inventory_store = merge(jsondecode(file("tests/fixtures/installation.json")).inventory_store, { prefix = "" }) })
  }
  expect_failures = [var.installation_facts]
}
run "activated_dp_requires_explicit_tenant_slug" {
  command = plan
  variables {
    activated               = true
    application_environment = { for role in ["sampler", "analyzer", "sampler-worker", "analyzer-worker"] : role => { GAI_NOTIFICATION_TENANT = "synthetic-tenant" } }
  }
  expect_failures = [terraform_data.contract]
}
run "derived_dp_environment_rejected" {
  command = plan
  variables { application_environment = { "data-pipelines" = { DP_RUNTIME_MODE = "shared" } } }
  expect_failures = [var.application_environment]
}

run "foreign_project_publish_topic_rejected" {
  command = plan
  variables { installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { publish_topic_paths = p.role == "data-pipelines" ? ["projects/foreign/topics/outbox"] : p.publish_topic_paths })] }) }
  expect_failures = [var.installation_facts]
}
run "exporter_publish_topic_rejected" {
  command = plan
  variables { installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { exporter = merge(jsondecode(file("tests/fixtures/installation.json")).exporter, { publish_topic_paths = ["projects/ecs-fixture/topics/outbox"] }) }) }
  expect_failures = [var.installation_facts]
}
run "enabled_producer_publish_topic_required" {
  command = plan
  variables { installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { publish_topic_paths = p.role == "data-pipelines" ? [] : p.publish_topic_paths })] }) }
  expect_failures = [var.installation_facts]
}

run "dp_inventory_folder_boundary_required" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      inventory_store = merge(jsondecode(file("tests/fixtures/installation.json")).inventory_store, { prefix = "inventory" })
    })
  }
  expect_failures = [var.installation_facts]
}
run "dp_outbox_folder_boundary_required" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      outbox_store = merge(jsondecode(file("tests/fixtures/installation.json")).outbox_store, { prefix = "outbox" })
    })
  }
  expect_failures = [var.installation_facts]
}

run "document_type_ack_delete_is_limited_to_analyzers_and_pending_findings" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      findings_store = { bucket = "custom-findings", prefix = "private/accepted/", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  assert {
    condition = alltrue([for role, p in aws_iam_role_policy.worker :
      contains(["analyzer", "analyzer-worker"], role) ?
      [for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:DeleteObject")] == [["arn:aws:s3:::custom-findings/private/accepted/gai_document_type_pending/*"]] :
      length([for s in jsondecode(p.policy).Statement : s if contains(s.Action, "s3:DeleteObject")]) == 0
    ]) && !strcontains(aws_iam_role_policy.exporter.policy, "s3:Delete")
    error_message = "Only analyzers may delete captured pending document-type sidecars; preserve every other store and exporter boundary."
  }
}

run "document_type_ack_without_trailing_slash" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      findings_store = { bucket = "custom-findings", prefix = "private/accepted", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  assert {
    condition = alltrue([for role, p in aws_iam_role_policy.worker :
      contains(["analyzer", "analyzer-worker"], role) ?
      [for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:DeleteObject")] == [["arn:aws:s3:::custom-findings/private/accepted/gai_document_type_pending/*"]] :
      length([for s in jsondecode(p.policy).Statement : s if contains(s.Action, "s3:DeleteObject")]) == 0
    ]) && !strcontains(aws_iam_role_policy.exporter.policy, "s3:Delete")
    error_message = "Only analyzers may delete captured pending document-type sidecars; preserve every other store and exporter boundary."
  }
}

run "document_type_ack_empty_prefix" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      findings_store = { bucket = "custom-findings", prefix = "", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  assert {
    condition = alltrue([for role, p in aws_iam_role_policy.worker :
      contains(["analyzer", "analyzer-worker"], role) ?
      [for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:DeleteObject")] == [["arn:aws:s3:::custom-findings/gai_document_type_pending/*"]] :
      length([for s in jsondecode(p.policy).Statement : s if contains(s.Action, "s3:DeleteObject")]) == 0
    ]) && !strcontains(aws_iam_role_policy.exporter.policy, "s3:Delete")
    error_message = "Only analyzers may delete captured pending document-type sidecars; preserve every other store and exporter boundary."
  }
}

run "document_type_ack_repeated_trailing_slashes" {
  command = plan
  variables {
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      findings_store = { bucket = "custom-findings", prefix = "private/accepted///", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  assert {
    condition = alltrue([for role, p in aws_iam_role_policy.worker :
      contains(["analyzer", "analyzer-worker"], role) ?
      [for s in jsondecode(p.policy).Statement : s.Resource if contains(s.Action, "s3:DeleteObject")] == [["arn:aws:s3:::custom-findings/private/accepted/gai_document_type_pending/*"]] :
      length([for s in jsondecode(p.policy).Statement : s if contains(s.Action, "s3:DeleteObject")]) == 0
    ]) && !strcontains(aws_iam_role_policy.exporter.policy, "s3:Delete")
    error_message = "Only analyzers may delete captured pending document-type sidecars; preserve every other store and exporter boundary."
  }
}

run "versioned_inventory_cleanup_disabled_by_default" {
  command = plan
  assert {
    condition     = alltrue([for policy in aws_iam_role_policy.worker : !strcontains(policy.policy, "s3:DeleteObjectVersion")])
    error_message = "Existing installations must not gain permanent object-version deletion by default."
  }
}
run "versioned_inventory_cleanup_scoped_to_dp_owned_batches" {
  command = plan
  variables {
    enable_versioned_inventory_result_cleanup = true
    installation_facts = merge(jsondecode(file("tests/fixtures/installation.json")), {
      outbox_store = { bucket = "custom-journals", prefix = "journals/explicit/", region = "us-west-2", owner_account_id = "111111111111" }
    })
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.worker["data-pipelines"].policy).Statement : s if contains(s.Action, "s3:DeleteObjectVersion")]) == 1 && one([for s in jsondecode(aws_iam_role_policy.worker["data-pipelines"].policy).Statement : s.Resource if contains(s.Action, "s3:DeleteObjectVersion")]) == ["arn:aws:s3:::custom-journals/journals/explicit/__outbox__/root_run=*/results/resource_type=*/partition=*/work=*/attempt=*/batch=*.parquet"]
    error_message = "Only DP may delete captured versions under its explicit temporary result path."
  }
  assert {
    condition     = alltrue([for role, policy in aws_iam_role_policy.worker : !strcontains(policy.policy, "s3:DeleteObjectVersion") if role != "data-pipelines"]) && !strcontains(aws_iam_role_policy.exporter.policy, "s3:DeleteObjectVersion")
    error_message = "Other roles and exporter must retain no object-version deletion permission."
  }
  assert {
    condition     = one([for e in jsondecode(aws_ecs_task_definition.worker["data-pipelines"].container_definitions)[0].environment : e.value if e.name == "DP_INHOST_VERSIONED_RESULT_CLEANUP"]) == "true"
    error_message = "The runtime cleanup opt-in must be paired with the exact task-role permission."
  }
}
run "versioned_inventory_cleanup_requires_dp" {
  command = plan
  variables {
    enable_versioned_inventory_result_cleanup = true
    installation_facts                        = merge(jsondecode(file("tests/fixtures/installation.json")), { pools = [for p in jsondecode(file("tests/fixtures/installation.json")).pools : merge(p, { enabled = p.role != "data-pipelines" })] })
  }
  expect_failures = [var.enable_versioned_inventory_result_cleanup]
}
