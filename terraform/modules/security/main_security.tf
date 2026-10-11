data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "irsa_trust_api" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:api"]
    }
  }
}

data "aws_iam_policy_document" "irsa_trust_worker" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:worker"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${var.name}-api-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust_api.json
  tags               = var.tags
}

resource "aws_iam_role" "worker" {
  name               = "${var.name}-worker-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust_worker.json
  tags               = var.tags
}

data "aws_iam_policy_document" "irsa_trust_keda" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:keda:keda-operator"]
    }
  }
}

resource "aws_iam_role" "keda" {
  name               = "${var.name}-keda-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust_keda.json
  tags               = var.tags
}

data "aws_iam_policy_document" "keda" {
  statement {
    sid       = "ScalerReadQueue"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }
}

resource "aws_iam_policy" "keda" {
  name   = "${var.name}-keda"
  policy = data.aws_iam_policy_document.keda.json
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "keda" {
  role       = aws_iam_role.keda.name
  policy_arn = aws_iam_policy.keda.arn
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "PutRawObjects"
    actions   = ["s3:PutObject"]
    resources = ["${var.raw_bucket_arn}/raw/*"]
  }
  statement {
    sid       = "HeadBucketForReadiness"
    actions   = ["s3:ListBucket"]
    resources = [var.raw_bucket_arn]
  }
  statement {
    sid       = "SendToQueue"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }
  statement {
    sid       = "ConnectToDatabase"
    actions   = ["rds-db:connect"]
    resources = ["arn:${data.aws_partition.current.partition}:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.db_resource_id}/${var.db_api_username}"]
  }
  statement {
    sid       = "UseKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "GetRawObjects"
    actions   = ["s3:GetObject"]
    resources = ["${var.raw_bucket_arn}/raw/*"]
  }
  statement {
    sid       = "ConsumeQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }
  statement {
    sid       = "ConnectToDatabase"
    actions   = ["rds-db:connect"]
    resources = ["arn:${data.aws_partition.current.partition}:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.db_resource_id}/${var.db_worker_username}"]
  }
  statement {
    sid       = "UseKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "${var.name}-api-policy"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_iam_role_policy" "worker" {
  name   = "${var.name}-worker-policy"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

data "aws_iam_policy_document" "irsa_trust_alertmanager" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values = [
        "system:serviceaccount:monitoring:alertmanager",
        "system:serviceaccount:monitoring:kube-prometheus-stack-alertmanager",
      ]
    }
  }
}

resource "aws_iam_role" "alertmanager" {
  name               = "${var.name}-alertmanager-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust_alertmanager.json
  tags               = var.tags
}

data "aws_iam_policy_document" "alertmanager" {
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.alerts_topic_arn]
  }
  statement {
    sid       = "UseKms"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "alertmanager" {
  name   = "${var.name}-alertmanager-policy"
  role   = aws_iam_role.alertmanager.id
  policy = data.aws_iam_policy_document.alertmanager.json
}

data "aws_iam_policy_document" "irsa_trust_fluentbit" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:fluent-bit"]
    }
  }
}

resource "aws_iam_role" "fluentbit" {
  name               = "${var.name}-fluentbit-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust_fluentbit.json
  tags               = var.tags
}

data "aws_iam_policy_document" "fluentbit" {
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${var.pod_log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "fluentbit" {
  name   = "${var.name}-fluentbit-policy"
  role   = aws_iam_role.fluentbit.id
  policy = data.aws_iam_policy_document.fluentbit.json
}
