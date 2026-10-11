variable "name" {
  type    = string
  default = "sales-pipeline"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace the app runs in"
  default     = "sales-pipeline"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS OIDC provider ARN (from cluster module). Empty until cluster exists."
  default     = ""
}

variable "oidc_provider_url" {
  type        = string
  description = "EKS OIDC provider URL without https:// (from cluster module)."
  default     = ""
}

variable "raw_bucket_arn" {
  type        = string
  description = "ARN of the raw-batch S3 bucket (from data module)."
  default     = ""
}

variable "sqs_queue_arn" {
  type        = string
  description = "ARN of the SQS jobs queue (from data module)."
  default     = ""
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN from the kms module"
  default     = ""
}

variable "pod_log_group_arn" {
  type        = string
  description = "ARN of the CloudWatch log group Fluent Bit writes pod logs to"
  default     = ""
}

variable "alerts_topic_arn" {
  type        = string
  description = "ARN of the SNS alerts topic Alertmanager publishes to (from data module)."
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS region, for the rds-db:connect resource ARN"
}

variable "db_resource_id" {
  type        = string
  description = "DB instance resource id for the rds-db:connect ARN"
}

variable "db_api_username" {
  type        = string
  description = "Dedicated IAM DB user for the API (rds_iam, created via scripts/db-bootstrap.sql)"
  default     = "app_api"
}

variable "db_worker_username" {
  type        = string
  description = "Dedicated IAM DB user for the worker (rds_iam, created via scripts/db-bootstrap.sql)"
  default     = "app_worker"
}
