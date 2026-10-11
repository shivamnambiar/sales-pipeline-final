# Terraform — Sales Pipeline Infrastructure

## Before you start: create the state bucket (CLI, one time)

The remote-state bucket can't be managed by the Terraform that uses it
(chicken-and-egg), so create it by CLI first. State locking is handled
natively by S3 (`use_lockfile=true`, Terraform 1.10+) — no DynamoDB table
needed.

```bash
aws s3 mb s3://YOUR-STATE-BUCKET --region "$AWS_REGION"   # the GitHub variable's value
aws s3api put-bucket-versioning --bucket YOUR-STATE-BUCKET \
  --versioning-configuration Status=Enabled
```

Leave default encryption at SSE-S3: the platform CodeBuild role has no KMS grant.

`backend.tf` is intentionally partial (`backend "s3" {}`) — the bucket, key,
region, and lock settings are injected at `init` time, in CI from secrets/vars:

```bash
terraform init \
  -backend-config="bucket=$TF_BACKEND_BUCKET" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

For a local run, pass the same flags (or use a `-backend-config=FILE.hcl`).

## Workflow

```bash
terraform fmt -recursive      # format + basic syntax
terraform init -backend-config=...   # see backend flags above
terraform validate            # internal coherence check
terraform plan                # shows what WOULD be created (no charges yet)
terraform apply               # creates resources (charges start here)
```

`platform-stack/` is a second root module with its own backend and providers,
so `validate`, `plan` and `apply` run separately there (from this directory:
`terraform -chdir=platform-stack validate`). `fmt -recursive` covers both.

## Module build order

Terraform derives the order from the references; a single apply sequences it.

1. **kms** — customer-managed KMS key (split out from security so it has no
   dependency on the cluster — this is what breaks the cluster↔security cycle).
2. **network** — VPC, 3 subnet tiers × 2 AZs, NAT gateway (permanent), VPC endpoints.
3. **data** — RDS Multi-AZ, SQS + DLQ, S3 raw bucket, ECR repos (kms-encrypted).
4. **cicd** — the in-VPC CodeBuild projects (platform apply, ArgoCD refresh).
5. **cluster** — EKS, Karpenter IAM + interruption queue, IRSA OIDC provider.
6. **security** — IRSA roles (least-privilege API-sends vs worker-consumes),
   trust scoped to the cluster's OIDC provider.

`modules/platform` (all the Helm releases) is loaded only by
`platform-stack/`, never by this stack.

## NAT strategy — NAT on (permanent)

`enable_nat = true` (the default in `variables.tf`) is permanent. The only
endpoints are the S3 gateway and two ECR interface endpoints
(`endpoints_network.tf`); they keep image-pull volume off the NAT, and
everything else egresses through it. Why this is closed rather than a toggle:
docs/DESIGN.md, "internet-egress saga".

## Teardown

Destroy order matters and is not symmetric with apply — RUNBOOK.md "Teardown"
has the sequence and the recovery path. Everything is reproducible from code.

## Apply-time notes

- **KMS key policy** authorizes the AWS service principals in `modules/kms`
  plus account-root admin. Encrypted-resource creation is two-sided
  authorization (principal IAM + key policy), so without it apply fails.
- **Confirm Postgres 16 is offered in your region** before the expensive apply.
  `postgres_version` is major-only so RDS picks a supported minor at create
  time, but RDS rejects an unavailable major at DB-create time — after the VPC
  and NAT are already billing:
  `aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion"`
- **Confirm the On-Demand vCPU quota** (`L-1216C47A`) before the apply: the two
  managed node groups need 16 and fail 15+ minutes in otherwise, and the first
  sync's Karpenter api nodes need about 6 more, so wait for at least 22 and
  request 32.
- **AWS provider attribute:** endpoints use `data.aws_region.current.name`.
  The `.region` attribute only exists in provider v6+; don't switch to it
  without bumping the `~> 5.0` pin.

## Two-stack structure (provider-deadlock fix)

The infra and platform layers are **separate root modules with separate state**,
because the `helm`/`kubernetes` providers must be configured from a cluster that
already exists. Configuring them from `module.cluster` outputs in a single apply
is the classic provider-bootstrap deadlock (provider config can't be evaluated
before the resource it depends on is created). The platform stack instead reads
`data.aws_eks_cluster`, so its provider config is fully resolvable at plan time.

```
terraform/                  # INFRA stack: kms, network, data, cicd, cluster, security
terraform/platform-stack/   # PLATFORM stack: all the Helm releases
```

### Apply order (two passes, deliberate)

Both passes run in CI, never from a workstation: the infra stack from the GitHub
runner (`terraform.yml` `apply`, state key `terraform.tfstate`), then the platform
stack from the in-VPC CodeBuild project `sales-pipeline-platform` (`platform-plan`
/ `platform-apply`, state key `platform.tfstate`). The platform stack's
helm/kubernetes providers talk to the private-only cluster endpoint, so a run from
outside the VPC times out; `region`, `tf_state_bucket` and `grafana_admin_password`
are supplied only inside CI (the last from Secrets Manager). Locally, the
supported operations are `init -backend=false` and `validate` on either stack,
plus, on the infra stack only, the backend-configured `init` (flags above) and
the `terraform output` that `scripts/bootstrap-overlay.sh` reads; never `plan`
or `apply` from a workstation.

State keys are FIXED by contract, not free to choose: infra is
`key=terraform.tfstate`, platform is `key=platform.tfstate`. The platform
stack's `terraform_remote_state` hardcodes the infra key, and CI passes these
exact keys — so a custom key like `infra/terraform.tfstate` either fails the
platform plan with "remote state not found" or silently creates a second empty
state, which then collides on globally-named resources (IAM roles, log groups,
SQS, ECR).
