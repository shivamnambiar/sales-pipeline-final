variable "name" {
  type    = string
  default = "sales-pipeline"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "account_id" {
  type        = string
  description = "AWS account ID, for globally-unique bucket naming"
}

variable "vpc_id" {
  type = string
}

variable "isolated_subnet_ids" {
  type        = list(string)
  description = "Isolated subnets for the RDS subnet group"
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs allowed to reach the DB"
}

variable "kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key ARN (from kms module)"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "postgres_version" {
  type        = string
  description = "Postgres major version. Major-only (e.g. '16') lets RDS pick a supported minor at create time, avoiding rolling minor-version deprecation. Pin a full minor only if you need reproducibility."
  default     = "16"
}

variable "visibility_timeout" {
  type        = number
  description = "SQS visibility timeout, set above worst-case batch processing time"
  default     = 300
}

variable "max_receive_count" {
  type    = number
  default = 3
}

variable "raw_retention_days" {
  type        = number
  description = "Days to keep raw batches in S3 before lifecycle expiry"
  default     = 30
}

variable "pod_log_retention_days" {
  type    = number
  default = 14
}

variable "scan_alert_email" {
  type        = string
  description = "Email for ECR image-scan CRITICAL/HIGH finding alerts. Empty disables the subscription (topic still created)."
  default     = ""
}
