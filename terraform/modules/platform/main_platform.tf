resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  namespace        = "kube-system"
  create_namespace = false
  version          = var.karpenter_version

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }
  set {
    name  = "settings.interruptionQueue"
    value = var.karpenter_queue_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.karpenter_controller_role_arn
  }
  set {
    name  = "replicas"
    value = "2"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "1000m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "nodeSelector.role"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].key"
    value = "role"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  namespace        = "kube-system"
  create_namespace = false
  version          = var.metrics_server_version

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.requests.memory"
    value = "200Mi"
  }
  set {
    name  = "resources.limits.memory"
    value = "200Mi"
  }
  set {
    name  = "nodeSelector.role"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].key"
    value = "role"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = var.keda_version

  set {
    name  = "serviceAccount.operator.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.keda_role_arn
  }
  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "100Mi"
  }
  set {
    name  = "resources.operator.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "resources.operator.limits.memory"
    value = "1000Mi"
  }
  set {
    name  = "resources.metricServer.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.metricServer.requests.memory"
    value = "100Mi"
  }
  set {
    name  = "resources.metricServer.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "resources.metricServer.limits.memory"
    value = "1000Mi"
  }
  set {
    name  = "resources.webhooks.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.webhooks.requests.memory"
    value = "100Mi"
  }
  set {
    name  = "resources.webhooks.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "resources.webhooks.limits.memory"
    value = "1000Mi"
  }
  set {
    name  = "nodeSelector.role"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].key"
    value = "role"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

resource "helm_release" "otel_operator" {
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  namespace        = "opentelemetry"
  create_namespace = true
  version          = var.otel_operator_version

  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-k8s"
  }
  set {
    name  = "admissionWebhooks.certManager.enabled"
    value = "false"
  }
  set {
    name  = "admissionWebhooks.autoGenerateCert.enabled"
    value = "true"
  }
  set {
    name  = "manager.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "manager.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "manager.resources.limits.cpu"
    value = "100m"
  }
  set {
    name  = "manager.resources.limits.memory"
    value = "64Mi"
  }
  set {
    name  = "nodeSelector.role"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].key"
    value = "role"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "bootstrap"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = var.kube_prometheus_stack_version

  values = [yamlencode({
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }
    alertmanager = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.alertmanager_role_arn
        }
      }
      config = {
        route = {
          group_by        = ["namespace", "alertname"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "12h"
          receiver        = "sns-alerts"
          routes = [
            {
              receiver = "blackhole"
              matchers = ["alertname = \"Watchdog\""]
            },
            {
              receiver = "blackhole"
              matchers = ["severity = \"info\""]
            },
          ]
        }
        receivers = [
          {
            name = "blackhole"
          },
          {
            name = "sns-alerts"
            sns_configs = [
              {
                topic_arn = var.alerts_topic_arn
                sigv4 = {
                  region = var.region
                }
              },
            ]
          },
        ]
      }
    }
  })]

  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = var.prometheus_retention
  }
  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "grafana.defaultDashboardsEnabled"
    value = "true"
  }
  set {
    name  = "grafana.additionalDataSources[0].name"
    value = "Tempo"
  }
  set {
    name  = "grafana.additionalDataSources[0].type"
    value = "tempo"
  }
  set {
    name  = "grafana.additionalDataSources[0].url"
    value = "http://tempo.monitoring:3200"
  }
  set {
    name  = "grafana.additionalDataSources[0].access"
    value = "proxy"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.cpu"
    value = "250m"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "prometheus.prometheusSpec.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "prometheus.prometheusSpec.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "prometheus.prometheusSpec.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "prometheus.prometheusSpec.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "prometheus.prometheusSpec.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.requests.memory"
    value = "400Mi"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.limits.cpu"
    value = "100m"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.resources.limits.memory"
    value = "400Mi"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "alertmanager.alertmanagerSpec.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "grafana.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "grafana.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "grafana.resources.limits.cpu"
    value = "100m"
  }
  set {
    name  = "grafana.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "grafana.sidecar.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "grafana.sidecar.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "grafana.sidecar.resources.limits.cpu"
    value = "50m"
  }
  set {
    name  = "grafana.sidecar.resources.limits.memory"
    value = "64Mi"
  }
  set {
    name  = "grafana.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "grafana.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "grafana.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "grafana.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "grafana.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "prometheusOperator.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "prometheusOperator.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "prometheusOperator.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "prometheusOperator.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "prometheusOperator.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "prometheusOperator.admissionWebhooks.patch.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "kube-state-metrics.nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "kube-state-metrics.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "kube-state-metrics.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "kube-state-metrics.tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "kube-state-metrics.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "prometheus-node-exporter.tolerations[0].operator"
    value = "Exists"
  }
}

resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana-community.github.io/helm-charts"
  chart            = "tempo"
  namespace        = "monitoring"
  create_namespace = true
  version          = var.tempo_version

  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  set {
    name  = "tempo.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "tempo.resources.requests.memory"
    value = "500Mi"
  }
  set {
    name  = "tempo.resources.limits.cpu"
    value = "500m"
  }
  set {
    name  = "tempo.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "nodeSelector.role"
    value = "monitoring"
  }
  set {
    name  = "tolerations[0].key"
    value = "role"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "monitoring"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "fluent_bit" {
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  namespace        = "amazon-cloudwatch"
  create_namespace = true
  version          = var.fluent_bit_version

  set {
    name  = "serviceAccount.name"
    value = "fluent-bit"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "resources.requests.cpu"
    value = "200m"
  }
  set {
    name  = "resources.requests.memory"
    value = "200Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "resources.limits.memory"
    value = "200Mi"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.fluentbit_role_arn
  }
  set {
    name  = "cloudWatchLogs.enabled"
    value = "true"
  }
  set {
    name  = "cloudWatchLogs.region"
    value = var.region
  }
  set {
    name  = "cloudWatchLogs.logGroupName"
    value = var.pod_log_group_name
  }
  set {
    name  = "cloudWatchLogs.logStreamPrefix"
    value = "pod-"
  }
  set {
    name  = "cloudWatchLogs.autoCreateGroup"
    value = "false"
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = var.argocd_version

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }
  set {
    name  = "global.nodeSelector.role"
    value = "bootstrap"
  }
  set {
    name  = "global.tolerations[0].key"
    value = "role"
  }
  set {
    name  = "global.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "global.tolerations[0].value"
    value = "bootstrap"
  }
  set {
    name  = "global.tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "server.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "server.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "server.resources.limits.cpu"
    value = "500m"
  }
  set {
    name  = "server.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "repoServer.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "repoServer.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "repoServer.resources.limits.cpu"
    value = "500m"
  }
  set {
    name  = "repoServer.resources.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "500m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "1Gi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }
  set {
    name  = "redis.resources.requests.cpu"
    value = "250m"
  }
  set {
    name  = "redis.resources.requests.memory"
    value = "200Mi"
  }
  set {
    name  = "redis.resources.limits.cpu"
    value = "350m"
  }
  set {
    name  = "redis.resources.limits.memory"
    value = "256Mi"
  }
}

resource "kubernetes_role" "argocd_refresher" {
  metadata {
    name      = "argocd-refresher"
    namespace = "argocd"
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "patch"]
  }
  depends_on = [helm_release.argocd]
}

resource "kubernetes_role_binding" "argocd_refresher" {
  metadata {
    name      = "argocd-refresher"
    namespace = "argocd"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argocd_refresher.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "argocd-refresher"
    api_group = "rbac.authorization.k8s.io"
  }
}
