variable "name" {
  type    = string
  default = "sales-pipeline"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "cluster_version" {
  type    = string
  default = "1.36"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key for envelope-encrypting Kubernetes secrets in etcd"
}

variable "public_endpoint" {
  type        = bool
  description = "Whether the EKS API endpoint is publicly reachable. Defaults false (fully private): the platform stack applies via in-VPC CodeBuild and humans use SSM port-forwarding (see RUNBOOK). True is an escape hatch only."
  default     = false
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the public EKS endpoint. Scope to known IPs; the endpoint is still IAM-authenticated and RBAC-authorized regardless."
  default     = ["0.0.0.0/0"]
}

variable "bootstrap_instance_type" {
  type    = string
  default = "c5.xlarge"
}

variable "bootstrap_min_size" {
  type    = number
  default = 3
}

variable "bootstrap_max_size" {
  type    = number
  default = 3
}

variable "bootstrap_desired_size" {
  type    = number
  default = 3
}

variable "monitoring_instance_type" {
  type    = string
  default = "c5.xlarge"
}

variable "monitoring_min_size" {
  type    = number
  default = 1
}

variable "monitoring_max_size" {
  type    = number
  default = 1
}

variable "monitoring_desired_size" {
  type    = number
  default = 1
}

variable "vpc_cni_version" {
  type        = string
  description = "Pinned vpc-cni addon version (must match cluster_version; verify with: aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version <ver>)"
  default     = "v1.22.1-eksbuild.2"
}

variable "coredns_version" {
  type        = string
  description = "Pinned coredns addon version (must match cluster_version)"
  default     = "v1.14.3-eksbuild.2"
}

variable "kube_proxy_version" {
  type        = string
  description = "Pinned kube-proxy addon version (must match cluster_version)"
  default     = "v1.36.0-eksbuild.7"
}

variable "control_plane_log_retention_days" {
  type        = number
  description = "Retention for EKS control-plane logs (api/audit/authenticator/controllerManager/scheduler)"
  default     = 90
}

variable "operator_principal_arn" {
  type        = string
  description = "IAM principal (your user/role ARN) to grant cluster admin via an access entry, so a human can run kubectl during bootstrap. Empty = no operator entry (CI role only)."
  default     = ""
}

variable "codebuild_role_arn" {
  type        = string
  description = "CodeBuild service role ARN - gets a cluster-admin access entry so the platform stack's helm/kubernetes providers can authenticate"
}

variable "codebuild_security_group_id" {
  type        = string
  description = "CodeBuild SG id - admitted by the cluster SG on 443 to reach the private endpoint"
}

variable "argocd_refresh_role_arn" {
  type        = string
  description = "The argocd-refresh CodeBuild role - gets EDIT scoped to the argocd namespace only (annotating the Application), deliberately not cluster admin"
}
