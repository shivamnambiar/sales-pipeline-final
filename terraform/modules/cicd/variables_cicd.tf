variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "state_bucket" {
  type        = string
  description = "The Terraform state bucket; also holds the CodeBuild source zip at codebuild/platform-src.zip"
}

variable "cluster_name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  type        = string
  description = "CMK for the build log groups - matches every other log group in the project"
}

variable "build_log_retention_days" {
  type    = number
  default = 30
}
