output "installation_facts" {
  description = "Nonsecret v1 facts with actual provisioned Redis endpoint. No token/password values."
  value       = local.runtime_facts
}
output "cluster_arn" { value = local.cluster_arn }
output "service_arns" { value = { for role, p in local.pools : role => "arn:aws:ecs:${local.facts.aws_region}:${local.facts.aws_account_id}:service/${local.cluster_name}/${p.service_name}" } }
output "task_execution_role_arn" {
  description = "Dedicated ECS image/log execution role ARN for registry reader onboarding."
  value       = aws_iam_role.execution.arn
}
output "task_role_arns" { value = { for role, p in local.pools : role => p.task_role_arn } }
output "exporter_task_role_arn" { value = local.facts.exporter.task_role_arn }
output "capacity_provider_names" { value = [for p in values(local.pools) : p.capacity_provider] }
output "task_security_group_id" { value = aws_security_group.task.id }
output "activation_state" { value = var.activated ? "active" : "held" }
