terraform {
  required_version = ">= 1.11, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.71, < 7.0" }
  }
}

variable "installation_facts_path" {
  description = "Validated Outpost installation-v1 JSON with FARGATE capacity providers for enabled roles."
  type        = string
}
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = set(string) }
variable "exporter_redis_secret_arn" { type = string }
variable "fargate_ephemeral_storage_gib" {
  description = "Optional override for total Fargate task ephemeral storage."
  type        = number
  default     = null
}
variable "create_cluster" {
  description = "Create the registered cluster and associate FARGATE. An existing cluster owner must associate FARGATE first."
  type        = bool
  default     = true
}

locals { facts = jsondecode(file(var.installation_facts_path)) }
provider "aws" { region = local.facts.aws_region }

module "ecs" {
  source                              = "../.."
  providers                           = { aws = aws, aws.secrets = aws }
  installation_facts                  = local.facts
  vpc_id                              = var.vpc_id
  private_subnet_ids                  = var.private_subnet_ids
  create_cluster                      = var.create_cluster
  manage_cluster_capacity_association = var.create_cluster
  exporter_redis_secret_arn           = var.exporter_redis_secret_arn
  fargate_ephemeral_storage_gib       = var.fargate_ephemeral_storage_gib
  activated                           = false
}

output "installation_facts" { value = module.ecs.installation_facts }
