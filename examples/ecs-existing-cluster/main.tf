terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.71, < 7.0" }
  }
}
variable "installation_facts_path" {
  description = "Validated installation-v1 JSON with exact existing cluster, provider and Redis facts, released images and role names owned by this module."
  type        = string
}
locals { facts = jsondecode(file(var.installation_facts_path)) }
provider "aws" { region = local.facts.aws_region }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = set(string) }
variable "existing_redis_security_group_id" { type = string }
variable "exporter_redis_secret_arn" { type = string }
variable "reviewed_capacity" {
  description = "Each role needs its own reservation and coordinator/child dependency proof, including providers shared with unrelated services."
  type = map(object({
    existing_provider = string
    max_instances     = number
    root_volume_gib   = number
    reservation_proof = object({ review_reference = string, reserved_tasks = number, independent_child_capacity = bool, zero_bootstrap_supported = bool })
  }))
}
module "ecs" {
  source             = "../.."
  providers          = { aws = aws, aws.secrets = aws }
  installation_facts = local.facts
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnet_ids
  activated          = false
  create_cluster     = false
  # Existing cluster owner retains the whole provider association, ASGs and quotas.
  manage_cluster_capacity_association = false
  capacity                            = var.reviewed_capacity
  provision_redis                     = false
  existing_redis_verified             = true
  existing_redis_security_group_id    = var.existing_redis_security_group_id
  exporter_redis_secret_arn           = var.exporter_redis_secret_arn
}
output "installation_facts" { value = module.ecs.installation_facts }
