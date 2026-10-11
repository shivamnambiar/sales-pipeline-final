output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "isolated_subnet_ids" {
  value = module.network.isolated_subnet_ids
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "rds_endpoint" {
  value = module.data.rds_endpoint
}

output "sqs_queue_url" {
  value = module.data.sqs_queue_url
}

output "raw_bucket_name" {
  value = module.data.raw_bucket_name
}

output "ecr_api_repo_url" {
  value = module.data.ecr_api_repo_url
}

output "ecr_worker_repo_url" {
  value = module.data.ecr_worker_repo_url
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "api_role_arn" {
  value = module.security.api_role_arn
}

output "worker_role_arn" {
  value = module.security.worker_role_arn
}

output "db_managed_password_secret_arn" {
  value = module.data.db_managed_password_secret_arn
}

output "karpenter_node_iam_role_name" {
  value       = module.cluster.karpenter_node_iam_role_name
  description = "Karpenter node IAM role - inject into the k8s EC2NodeClass"
}

output "fluentbit_role_arn" {
  value = module.security.fluentbit_role_arn
}

output "pod_log_group_name" {
  value = module.data.pod_log_group_name
}

output "vpc_cidr" {
  value = var.vpc_cidr
}

output "region" {
  value = var.region
}

output "karpenter_controller_role_arn" {
  value       = module.cluster.karpenter_controller_role_arn
  description = "Karpenter controller IRSA role ARN - for the controller Helm release"
}

output "karpenter_queue_name" {
  value       = module.cluster.karpenter_queue_name
  description = "Karpenter interruption queue name - for the controller Helm release"
}

output "image_scan_alerts_topic_arn" {
  value       = module.data.image_scan_alerts_topic_arn
  description = "SNS topic for ECR image-scan finding alerts"
}

output "db_name" {
  value = module.data.db_name
}

output "db_username" {
  value = module.data.db_username
}

output "keda_role_arn" {
  value = module.security.keda_role_arn
}

output "alertmanager_role_arn" {
  value       = module.security.alertmanager_role_arn
  description = "Alertmanager IRSA role ARN - annotate onto the alertmanager service account"
}

output "codebuild_project_name" {
  value = module.cicd.codebuild_project_name
}
