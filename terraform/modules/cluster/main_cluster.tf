module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access       = var.public_endpoint
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs
  cluster_endpoint_private_access      = true

  enable_irsa = true

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  cloudwatch_log_group_kms_key_id        = var.kms_key_arn
  cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days

  cluster_addons = {
    vpc-cni = {
      addon_version  = var.vpc_cni_version
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        tolerations = [
          {
            operator = "Exists"
          }
        ]
      })
    }
    coredns = {
      addon_version = var.coredns_version
      configuration_values = jsonencode({
        nodeSelector = {
          role = "bootstrap"
        }
        tolerations = [
          {
            key      = "role"
            operator = "Equal"
            value    = "bootstrap"
            effect   = "NoSchedule"
          }
        ]
      })
    }
    kube-proxy = {
      addon_version = var.kube_proxy_version
    }
  }

  eks_managed_node_groups = {
    bootstrap = {
      instance_types = [var.bootstrap_instance_type]
      min_size       = var.bootstrap_min_size
      max_size       = var.bootstrap_max_size
      desired_size   = var.bootstrap_desired_size
      subnet_ids     = var.private_subnet_ids

      labels = {
        role = "bootstrap"
      }

      taints = {
        role = {
          key    = "role"
          value  = "bootstrap"
          effect = "NO_SCHEDULE"
        }
      }

      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
    monitoring = {
      instance_types = [var.monitoring_instance_type]
      min_size       = var.monitoring_min_size
      max_size       = var.monitoring_max_size
      desired_size   = var.monitoring_desired_size
      subnet_ids     = var.private_subnet_ids

      labels = {
        role = "monitoring"
      }

      taints = {
        role = {
          key    = "role"
          value  = "monitoring"
          effect = "NO_SCHEDULE"
        }
      }

      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  cluster_encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }
  create_kms_key = false

  enable_cluster_creator_admin_permissions = true

  cluster_security_group_additional_rules = {
    codebuild_https = {
      description              = "CodeBuild platform runner to the private EKS endpoint"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = var.codebuild_security_group_id
    }
  }

  access_entries = merge(
    var.operator_principal_arn == "" ? {} : {
      operator = {
        principal_arn = var.operator_principal_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    {
      codebuild = {
        principal_arn = var.codebuild_role_arn
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
      argocd_refresh = {
        principal_arn     = var.argocd_refresh_role_arn
        kubernetes_groups = ["argocd-refresher"]
      }
    }
  )

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.name
  }

  tags = var.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions = true
  namespace             = "kube-system"

  enable_irsa                     = true
  enable_pod_identity             = false
  create_pod_identity_association = false
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.name}-karpenter-node"

  node_iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}
