terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.71, < 7.0" }
  }
}
locals {
  # Synthetic contract example only. Replace with validated enrollment facts and
  # released image digests before preparing any installation plan.
  facts = jsondecode(file("${path.module}/../../tests/fixtures/installation.json"))
}
provider "aws" { region = local.facts.aws_region }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = set(string) }
variable "ecs_optimized_ami_id" {
  description = "Reviewed immutable ECS-optimized AL2023 x86_64 AMI for the exact region; ECS agent must support 600s EC2 task stop."
  type        = string
}
variable "exporter_redis_secret_arn" { type = string }
module "ecs" {
  source             = "../.."
  providers          = { aws = aws, aws.secrets = aws }
  installation_facts = local.facts
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  activated          = false
  # Module owns one provider/ASG per role. Never copy synthetic values into live facts.
  capacity = { for p in local.facts.pools : p.role => {
    instance_type   = "r6i.4xlarge"
    ami_id          = var.ecs_optimized_ami_id
    max_instances   = 3
    root_volume_gib = 200
  } }
  provision_redis           = true
  exporter_redis_secret_arn = var.exporter_redis_secret_arn
}
output "installation_facts" { value = module.ecs.installation_facts }
