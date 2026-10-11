variable "cluster_name" {
  type = string
}

variable "keda_version" {
  type    = string
  default = "2.20.2"
}

variable "otel_operator_version" {
  type    = string
  default = "0.112.0"
}

variable "kube_prometheus_stack_version" {
  type    = string
  default = "88.6.1"
}

variable "prometheus_retention" {
  type    = string
  default = "15d"
}

variable "grafana_admin_password" {
  type        = string
  description = "Grafana admin password. Pass via TF_VAR or a secret, not committed."
  default     = ""
  sensitive   = true
}

variable "tempo_version" {
  type    = string
  default = "2.2.3"
}

variable "fluent_bit_version" {
  type    = string
  default = "0.2.0"
}

variable "fluentbit_role_arn" {
  type    = string
  default = ""
}

variable "pod_log_group_name" {
  type    = string
  default = ""
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "argocd_version" {
  type    = string
  default = "10.4.0"
}

variable "karpenter_version" {
  type    = string
  default = "1.14.1"
}

variable "cluster_endpoint" {
  type    = string
  default = ""
}

variable "karpenter_queue_name" {
  type    = string
  default = ""
}

variable "karpenter_controller_role_arn" {
  type    = string
  default = ""
}

variable "keda_role_arn" {
  type        = string
  description = "IRSA role ARN to annotate on the KEDA operator service account"
}

variable "alertmanager_role_arn" {
  type        = string
  description = "IRSA role ARN to annotate on the Alertmanager service account, for sns:Publish"
}

variable "alerts_topic_arn" {
  type        = string
  description = "SNS topic ARN Alertmanager publishes firing and resolved alerts to"
}

variable "metrics_server_version" {
  type        = string
  description = "metrics-server Helm chart version (for the API HPA resource metrics)"
  default     = "3.13.0"
}
