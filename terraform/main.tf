data "aws_caller_identity" "current" {}

module "kms" {
  source = "./modules/kms"
  name   = var.name
  region = var.region
}

module "network" {
  source = "./modules/network"

  name        = var.name
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  enable_nat  = var.enable_nat
  kms_key_arn = module.kms.kms_key_arn
  single_nat  = var.single_nat
}

module "security" {
  source = "./modules/security"

  name      = var.name
  namespace = var.namespace

  kms_key_arn = module.kms.kms_key_arn

  oidc_provider_arn = module.cluster.oidc_provider_arn
  oidc_provider_url = module.cluster.oidc_provider_url

  raw_bucket_arn    = module.data.raw_bucket_arn
  sqs_queue_arn     = module.data.sqs_queue_arn
  pod_log_group_arn = module.data.pod_log_group_arn
  alerts_topic_arn  = module.data.image_scan_alerts_topic_arn

  region         = var.region
  db_resource_id = module.data.db_resource_id
}

module "data" {
  source = "./modules/data"

  name                 = var.name
  account_id           = data.aws_caller_identity.current.account_id
  vpc_id               = module.network.vpc_id
  isolated_subnet_ids  = module.network.isolated_subnet_ids
  private_subnet_cidrs = module.network.private_subnet_cidrs
  kms_key_arn          = module.kms.kms_key_arn
  scan_alert_email     = var.scan_alert_email
}

module "cicd" {
  source = "./modules/cicd"

  name               = var.name
  region             = var.region
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  state_bucket       = var.tf_state_bucket
  cluster_name       = var.name
  kms_key_arn        = module.kms.kms_key_arn
}

module "cluster" {
  source = "./modules/cluster"

  name                   = var.name
  vpc_id                 = module.network.vpc_id
  private_subnet_ids     = module.network.private_subnet_ids
  kms_key_arn            = module.kms.kms_key_arn
  public_endpoint        = var.eks_public_endpoint
  public_access_cidrs    = var.eks_public_access_cidrs
  operator_principal_arn = var.operator_principal_arn

  codebuild_role_arn          = module.cicd.codebuild_role_arn
  codebuild_security_group_id = module.cicd.codebuild_security_group_id
  argocd_refresh_role_arn     = module.cicd.argocd_refresh_role_arn
}
