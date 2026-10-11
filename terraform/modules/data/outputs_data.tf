output "rds_endpoint" {
  value       = aws_db_instance.this.address
  description = "RDS endpoint hostname"
}

output "sqs_queue_url" {
  value       = aws_sqs_queue.jobs.url
  description = "Jobs queue URL"
}

output "sqs_queue_arn" {
  value       = aws_sqs_queue.jobs.arn
  description = "Jobs queue ARN"
}

output "dlq_url" {
  value       = aws_sqs_queue.dlq.url
  description = "Dead-letter queue URL"
}

output "raw_bucket_name" {
  value       = aws_s3_bucket.raw.bucket
  description = "Raw-batch S3 bucket name"
}

output "raw_bucket_arn" {
  value       = aws_s3_bucket.raw.arn
  description = "Raw-batch S3 bucket ARN"
}

output "db_managed_password_secret_arn" {
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  description = "ARN of the RDS-managed master password secret (username/password); never transits TF state"
}

output "ecr_api_repo_url" {
  value       = aws_ecr_repository.api.repository_url
  description = "ECR repo URL for the API image"
}

output "ecr_worker_repo_url" {
  value       = aws_ecr_repository.worker.repository_url
  description = "ECR repo URL for the worker image"
}

output "pod_log_group_name" {
  value       = aws_cloudwatch_log_group.pod_logs.name
  description = "CloudWatch log group for pod logs (Fluent Bit target)"
}

output "pod_log_group_arn" {
  value       = aws_cloudwatch_log_group.pod_logs.arn
  description = "ARN of the pod-logs CloudWatch log group"
}

output "db_resource_id" {
  value       = aws_db_instance.this.resource_id
  description = "DB instance resource id, for the rds-db:connect IAM resource ARN"
}

output "db_username" {
  value       = aws_db_instance.this.username
  description = "DB user for IAM auth (rds-db:connect dbuser)"
}

output "image_scan_alerts_topic_arn" {
  value = aws_sns_topic.image_scan_alerts.arn
}

output "db_name" {
  value       = aws_db_instance.this.db_name
  description = "DB name for the app connection"
}
