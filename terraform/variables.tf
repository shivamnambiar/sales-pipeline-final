variable "region" {
  type        = string
  description = "AWS region. Supplied only by CI as TF_VAR_region from the AWS_REGION repository variable. Deliberately has no default so a local run without it fails loudly instead of silently targeting the wrong region."
}

variable "name" {
  type        = string
  description = "Name prefix for all resources"
  default     = "sales-pipeline"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of AZs to span"
  default     = 2
}

variable "enable_nat" {
  type        = bool
  description = "Create a NAT gateway for private-subnet egress. Must be true for this design: ArgoCD (GitHub), Karpenter (IAM API), and platform image pulls from public registries have no VPC endpoints. See docs/DESIGN.md."
  default     = true
}

variable "single_nat" {
  type        = bool
  description = "Use one shared NAT (true, cheaper) vs one-per-AZ (false, production-correct)."
  default     = true
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace the app runs in"
  default     = "sales-pipeline"
}

variable "eks_public_endpoint" {
  type        = bool
  description = "Whether the EKS API endpoint is public. FALSE (the default): fully private - platform stack applies run from in-VPC CodeBuild; human kubectl uses SSM port-forwarding (RUNBOOK). True re-opens the public endpoint (IAM+RBAC gated) as an escape hatch."
  default     = false
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public EKS endpoint. Set to your IP (e.g. [\"203.0.113.4/32\"]) rather than the open default. Endpoint is IAM+RBAC gated regardless."
  default     = ["0.0.0.0/0"]
}

variable "scan_alert_email" {
  type        = string
  description = "Email for ECR image-scan CRITICAL/HIGH alerts. Empty disables the email subscription."
  default     = ""
}

variable "operator_principal_arn" {
  type        = string
  description = "Human operator IAM ARN for kubectl access during bootstrap (see cluster module)."
  default     = ""
}

variable "tf_state_bucket" {
  type        = string
  description = "The Terraform state bucket (also holds the CodeBuild platform source zip). Passed as TF_VAR_tf_state_bucket by CI."
}
