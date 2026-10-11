output "api_role_arn" {
  value       = aws_iam_role.api.arn
  description = "IRSA role ARN for the API service account"
}

output "worker_role_arn" {
  value       = aws_iam_role.worker.arn
  description = "IRSA role ARN for the worker service account"
}

output "fluentbit_role_arn" {
  value       = aws_iam_role.fluentbit.arn
  description = "IRSA role ARN for the Fluent Bit service account"
}

output "keda_role_arn" {
  value       = aws_iam_role.keda.arn
  description = "IRSA role ARN for the KEDA operator (annotate onto serviceAccount.operator)"
}

output "alertmanager_role_arn" {
  value       = aws_iam_role.alertmanager.arn
  description = "IRSA role ARN for the Alertmanager service account (SNS publish)"
}
