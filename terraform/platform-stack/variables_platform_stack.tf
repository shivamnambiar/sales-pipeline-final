variable "region" {
  type        = string
  description = "AWS region. Supplied only by CI as TF_VAR_region. No default, by design."
}

variable "cluster_name" {
  type        = string
  description = "Name of the existing EKS cluster (output by the infra stack)"
  default     = "sales-pipeline"
}

variable "grafana_admin_password" {
  type        = string
  description = "Grafana admin password. In CI this resolves from the sales-pipeline/grafana-admin Secrets Manager secret inside CodeBuild; locally pass TF_VAR_grafana_admin_password."
  sensitive   = true

  validation {
    condition     = length(var.grafana_admin_password) > 0
    error_message = "grafana_admin_password is empty. The sales-pipeline/grafana-admin Secrets Manager secret is unset or resolved empty - create/set it (RUNBOOK Phase 0 step 5c) rather than shipping a passwordless Grafana."
  }
}

variable "prometheus_retention" {
  type    = string
  default = "15d"
}


variable "tf_state_bucket" {
  type        = string
  description = "S3 bucket holding the infra stack state (for terraform_remote_state)"
}
