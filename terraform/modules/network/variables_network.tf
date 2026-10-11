variable "name" {
  type        = string
  description = "Name prefix for all network resources"
  default     = "sales-pipeline"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of availability zones to span"
  default     = 2
}

variable "enable_nat" {
  type        = bool
  description = "Whether to create a NAT gateway for private-subnet egress. Must be true for this design: ArgoCD reaches GitHub, Karpenter reaches the IAM API, and the platform pulls public images, none of which have VPC endpoints."
  default     = true
}

variable "single_nat" {
  type        = bool
  description = "If NAT is enabled, use one shared NAT (true, cheaper, one-AZ risk) vs one-per-AZ (false, production-correct). Demo default true."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources"
  default     = {}
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN for encrypting the VPC flow log group"
  default     = ""
}

variable "flow_logs_retention_days" {
  type    = number
  default = 14
}
