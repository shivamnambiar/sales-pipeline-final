resource "aws_ecr_repository" "api" {
  name                 = "${var.name}-api"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
  tags = var.tags
}

resource "aws_ecr_repository" "worker" {
  name                 = "${var.name}-worker"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
  tags = var.tags
}

resource "aws_s3_bucket" "raw" {
  bucket = "${var.name}-raw-${var.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "raw" {
  bucket = aws_s3_bucket.raw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.raw.arn,
          "${aws_s3_bucket.raw.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.raw]
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    id     = "expire-raw-batches"
    status = "Enabled"
    filter {
      prefix = "raw/"
    }
    expiration {
      days = var.raw_retention_days
    }
  }
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-jobs-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = var.kms_key_arn
  tags                      = var.tags
}

resource "aws_sqs_queue" "jobs" {
  name                       = "${var.name}-jobs"
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = 345600
  kms_master_key_id          = var.kms_key_arn
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue_policy" "jobs" {
  queue_url = aws_sqs_queue.jobs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.jobs.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.dlq.arn
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnet"
  subnet_ids = var.isolated_subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "Allow Postgres from the private subnets (pods) only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres from private subnets (pods, IAM-authenticated)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  tags = merge(var.tags, { Name = "${var.name}-db-sg" })
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_name  = "pipeline"
  username = "pipeline"

  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  iam_database_authentication_enabled = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period         = 7
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  enabled_cloudwatch_logs_exports = ["postgresql"]

  skip_final_snapshot = true
  deletion_protection = false

  tags = var.tags

  depends_on = [aws_cloudwatch_log_group.rds_postgresql]
}

resource "aws_cloudwatch_log_group" "pod_logs" {
  name              = "/eks/${var.name}/pod-logs"
  retention_in_days = var.pod_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${var.name}-db/postgresql"
  retention_in_days = var.pod_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "scan_alerts" {
  name              = "/aws/events/${var.name}/scan-alerts"
  retention_in_days = var.pod_log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic" "image_scan_alerts" {
  name              = "${var.name}-image-scan-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "image_scan_email" {
  count     = var.scan_alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.image_scan_alerts.arn
  protocol  = "email"
  endpoint  = var.scan_alert_email
}

resource "aws_cloudwatch_event_rule" "ecr_scan_findings" {
  name        = "${var.name}-ecr-scan-findings"
  description = "ECR image scan completed with CRITICAL findings"
  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Scan"]
    detail = {
      repository-name = [aws_ecr_repository.api.name, aws_ecr_repository.worker.name]
      finding-severity-counts = {
        CRITICAL = [{ numeric = [">", 0] }]
      }
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "ecr_scan_findings_high" {
  name        = "${var.name}-ecr-scan-findings-high"
  description = "ECR image scan completed with HIGH findings"
  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Scan"]
    detail = {
      repository-name = [aws_ecr_repository.api.name, aws_ecr_repository.worker.name]
      finding-severity-counts = {
        HIGH = [{ numeric = [">", 0] }]
      }
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "scan_critical_to_sns" {
  rule      = aws_cloudwatch_event_rule.ecr_scan_findings.name
  target_id = "sns-critical"
  arn       = aws_sns_topic.image_scan_alerts.arn
}

resource "aws_cloudwatch_event_target" "scan_high_to_sns" {
  rule      = aws_cloudwatch_event_rule.ecr_scan_findings_high.name
  target_id = "sns-high"
  arn       = aws_sns_topic.image_scan_alerts.arn
}

resource "aws_cloudwatch_event_target" "scan_critical_to_logs" {
  rule      = aws_cloudwatch_event_rule.ecr_scan_findings.name
  target_id = "logs-critical"
  arn       = aws_cloudwatch_log_group.scan_alerts.arn
}

resource "aws_cloudwatch_event_target" "scan_high_to_logs" {
  rule      = aws_cloudwatch_event_rule.ecr_scan_findings_high.name
  target_id = "logs-high"
  arn       = aws_cloudwatch_log_group.scan_alerts.arn
}

data "aws_iam_policy_document" "scan_alerts_logs" {
  statement {
    sid       = "AllowEventBridgeToLog"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.scan_alerts.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "scan_alerts" {
  policy_name     = "${var.name}-scan-alerts-events"
  policy_document = data.aws_iam_policy_document.scan_alerts_logs.json
}

data "aws_iam_policy_document" "sns_scan_alerts" {
  statement {
    sid     = "AllowEventBridgePublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.image_scan_alerts.arn]
  }
  statement {
    sid     = "AllowCloudWatchAlarmsPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    resources = [aws_sns_topic.image_scan_alerts.arn]
  }
  statement {
    sid     = "AllowAccountPrincipalsPublish"
    effect  = "Allow"
    actions = ["sns:Publish"]
    principals {
      type        = "AWS"
      identifiers = [var.account_id]
    }
    resources = [aws_sns_topic.image_scan_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "image_scan_alerts" {
  arn    = aws_sns_topic.image_scan_alerts.arn
  policy = data.aws_iam_policy_document.sns_scan_alerts.json
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-dlq-not-empty"
  alarm_description   = "Messages present in the DLQ — worker failed a batch beyond redrive (crash/OOM redrives land here silently, esp. after scale-to-zero)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }
  alarm_actions = [aws_sns_topic.image_scan_alerts.arn]
  tags          = var.tags
}
