resource "aws_security_group" "codebuild" {
  name        = "${var.name}-codebuild-sg"
  description = "CodeBuild platform-apply runner: egress-only (EKS API in-VPC, providers/charts via NAT, S3/ECR via endpoints)"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to the EKS private endpoint, VPC endpoints, and (via NAT) provider/chart registries"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-codebuild-sg" })
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name}-codebuild-platform"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid = "OwnBuildLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-platform:*",
    ]
  }

  statement {
    sid = "VpcNetworking"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "VpcEniPermission"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values = [
        for id in var.private_subnet_ids :
        "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:subnet/${id}"
      ]
    }
  }

  statement {
    sid     = "StateAndSource"
    actions = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket}/*",
    ]
  }

  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }

  statement {
    sid       = "GrafanaSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/grafana-admin-*"]
  }
}

resource "aws_iam_policy" "codebuild" {
  name   = "${var.name}-codebuild-platform"
  policy = data.aws_iam_policy_document.codebuild.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "codebuild" {
  role       = aws_iam_role.codebuild.name
  policy_arn = aws_iam_policy.codebuild.arn
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_log_group" "platform_build" {
  name              = "/aws/codebuild/${var.name}-platform"
  retention_in_days = var.build_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_codebuild_project" "platform" {
  name          = "${var.name}-platform"
  description   = "Runs terraform plan/apply for the platform stack from INSIDE the VPC, so it can reach the private EKS endpoint"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 45

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    environment_variable {
      name  = "TF_COMMAND"
      value = "plan"
    }

    environment_variable {
      name  = "TF_VAR_grafana_admin_password"
      value = "${var.name}/grafana-admin"
      type  = "SECRETS_MANAGER"
    }
  }

  source {
    type      = "S3"
    location  = "${var.state_bucket}/codebuild/platform-src.zip"
    buildspec = "terraform/platform-stack/buildspec.yml"
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.platform_build.name
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "argocd_refresh" {
  name               = "${var.name}-codebuild-argocd-refresh"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "argocd_refresh" {
  statement {
    sid = "OwnBuildLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-argocd-refresh:*",
    ]
  }

  statement {
    sid = "VpcNetworking"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "VpcEniPermission"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "ec2:Subnet"
      values = [
        for id in var.private_subnet_ids :
        "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:subnet/${id}"
      ]
    }
  }

  statement {
    sid       = "DescribeCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${data.aws_partition.current.partition}:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_policy" "argocd_refresh" {
  name   = "${var.name}-codebuild-argocd-refresh"
  policy = data.aws_iam_policy_document.argocd_refresh.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "argocd_refresh" {
  role       = aws_iam_role.argocd_refresh.name
  policy_arn = aws_iam_policy.argocd_refresh.arn
}

resource "aws_cloudwatch_log_group" "argocd_refresh_build" {
  name              = "/aws/codebuild/${var.name}-argocd-refresh"
  retention_in_days = var.build_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_codebuild_project" "argocd_refresh" {
  name          = "${var.name}-argocd-refresh"
  description   = "Forces an immediate ArgoCD refresh after app.yml pins new image tags - minimal role, namespace-scoped cluster access, deliberately SEPARATE from the cluster-admin platform project"
  service_role  = aws_iam_role.argocd_refresh.arn
  build_timeout = 10

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type         = "LINUX_CONTAINER"
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-BUILDSPEC
      version: 0.2
      env:
        variables:
          KUBECTL_VERSION: "v1.36.0"
      phases:
        install:
          commands:
            - curl -sSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
            - chmod +x /usr/local/bin/kubectl
        build:
          commands:
            - aws eks update-kubeconfig --name ${var.cluster_name} --region $AWS_REGION
            - kubectl annotate application sales-pipeline -n argocd argocd.argoproj.io/refresh=hard --overwrite
      BUILDSPEC
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.argocd_refresh_build.name
    }
  }

  tags = var.tags
}
