module "platform" {
  source = "../modules/platform"

  cluster_name           = var.cluster_name
  grafana_admin_password = var.grafana_admin_password
  prometheus_retention   = var.prometheus_retention
  region                 = var.region
  fluentbit_role_arn     = data.terraform_remote_state.infra.outputs.fluentbit_role_arn
  pod_log_group_name     = data.terraform_remote_state.infra.outputs.pod_log_group_name

  cluster_endpoint              = data.terraform_remote_state.infra.outputs.cluster_endpoint
  karpenter_queue_name          = data.terraform_remote_state.infra.outputs.karpenter_queue_name
  karpenter_controller_role_arn = data.terraform_remote_state.infra.outputs.karpenter_controller_role_arn
  keda_role_arn                 = data.terraform_remote_state.infra.outputs.keda_role_arn
  alertmanager_role_arn         = data.terraform_remote_state.infra.outputs.alertmanager_role_arn
  alerts_topic_arn              = data.terraform_remote_state.infra.outputs.image_scan_alerts_topic_arn
}
