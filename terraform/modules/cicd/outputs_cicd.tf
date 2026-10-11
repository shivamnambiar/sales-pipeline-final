output "codebuild_project_name" {
  value       = aws_codebuild_project.platform.name
  description = "CodeBuild project GHA starts for platform plan/apply"
}

output "codebuild_role_arn" {
  value       = aws_iam_role.codebuild.arn
  description = "Service role ARN - gets an EKS access entry so helm/kubernetes providers can auth"
}

output "codebuild_security_group_id" {
  value       = aws_security_group.codebuild.id
  description = "CodeBuild SG - admitted by the cluster SG on 443"
}

output "argocd_refresh_project_name" {
  value       = aws_codebuild_project.argocd_refresh.name
  description = "CodeBuild project app.yml starts to force an immediate ArgoCD refresh"
}

output "argocd_refresh_role_arn" {
  value       = aws_iam_role.argocd_refresh.arn
  description = "Minimal role - gets a NAMESPACE-scoped (argocd) access entry, not cluster admin"
}
