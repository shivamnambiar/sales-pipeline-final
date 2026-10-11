output "keda_namespace" {
  value = helm_release.keda.namespace
}

output "monitoring_namespace" {
  value = helm_release.kube_prometheus_stack.namespace
}

output "grafana_service" {
  value       = "kube-prometheus-stack-grafana.monitoring.svc.cluster.local"
  description = "In-cluster Grafana service DNS (port-forward to access)"
}
