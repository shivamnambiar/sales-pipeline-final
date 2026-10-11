# Terraform CI role policy

`terraform-ci-role-policy.json` is the permissions policy for the IAM role the
Terraform workflow assumes via OIDC (`AWS_TF_ROLE_ARN`). Attach it to that role,
and set the role's trust policy to your GitHub OIDC provider scoped to this repo.

Replace `REPLACE_TF_STATE_BUCKET` with your Terraform state bucket name. In the
matching trust policy, `terraform-ci-role-trust.json`, fill `ACCOUNT_ID`,
`OWNER_ID` and `REPO_ID` as quoted strings. Create the role with
`--max-session-duration 7200`: the workflow's `apply` job requests a two-hour
session (`role-duration-seconds: 7200`), and the assume fails if the role's
maximum is lower.

## Scoping rationale (deliberate, defensible)

- **Service-level (e.g. `ec2:*`) for EC2, EKS, ECR, RDS, SQS, S3, KMS, Secrets
  Manager, SNS, EventBridge, CloudWatch and Logs.** These are the services the
  infra actually creates. Broad within each service so the first apply doesn't
  fail on an un-enumerated describe/tag action, but bounded to those services.
  In a shared or production account you'd tighten to per-action least-privilege
  (derive the set with CloudTrail or `iamlive` during a real apply) and add
  region/tag conditions.
- **The state-backend statement is resource-scoped** to the state bucket. Note
  the separate `s3:*` statement is account-wide, so S3 access overall is not
  bucket-limited.
- **IAM is enumerated, NOT `iam:*`** — to bound the action set to what the
  cluster/IRSA roles, the OIDC provider and instance profiles need. It is not an
  anti-escalation control: `iam:AttachRolePolicy` and `iam:PutRolePolicy` on `*`
  still let the role widen any role, itself included, so this stays a
  single-account bootstrap credential; closing that needs a permissions boundary.

## Known caveats

- `iam:PassRole` is `Resource: "*"` because the role ARNs being passed aren't known
  until creation. Scope it to specific role ARNs once known.
- The IAM action list may be missing one or two actions the EKS/Karpenter modules
  need — IAM was kept tight deliberately, so it's the most likely place a first
  apply hits `AccessDenied`. Read the missing action from the error and add it.
- CodeBuild is action-scoped too: a run set (StartBuild/BatchGetBuilds/StopBuild)
  on the platform project only (the app role starts the refresh project), a lifecycle set
  (Create/BatchGet/Update/DeleteProject) on `sales-pipeline-*`, and a
  `DenyBuildspecOverride` refusing any StartBuild with a buildspec override.
