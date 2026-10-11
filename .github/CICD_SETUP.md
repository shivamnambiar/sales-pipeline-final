# CI/CD Setup

Three GitHub Actions workflows:

- **terraform.yml** — `fmt`/`validate`/`plan` on PRs touching `terraform/**` (or
  the workflow file itself); auto-`apply` on merge to `main`, then the two
  platform jobs.
- **app.yml** — tests on every PR touching `api/**`, `worker/**` or its own file;
  on merge to `main`, builds both images, scans with Trivy, pushes to ECR tagged
  with the Git SHA, then pins that SHA into `k8s/overlays/prod` and commits.
  ArgoCD syncs the cluster from Git — the workflow never touches EKS directly.
- **k8s-validate.yml** — every PR and every push to `main`, no path filter. Its
  `validate` job runs the shared gate (`scripts/validate-manifests.sh`); its
  `guardrails` job shellchecks `scripts/*.sh` + `smoke.sh` and parses
  `.claude/settings.json`. It touches no AWS.

terraform.yml and app.yml authenticate to AWS via **GitHub OIDC** — no stored
AWS keys. k8s-validate.yml needs no credentials.

## What you must configure in GitHub

### Repository secrets (Settings → Secrets and variables → Actions → Secrets)
| Secret | What it is |
|---|---|
| `AWS_TF_ROLE_ARN` | ARN of the IAM role the Terraform workflow assumes via OIDC |
| `AWS_APP_ROLE_ARN` | ARN of the IAM role the app workflow assumes — ECR push plus the ArgoCD refresh trigger; policy in `docs/app-ci-role-policy.json`, rationale under "The OIDC roles" |
| `TF_BACKEND_BUCKET` | Name of your Terraform state S3 bucket (created in `AWS_REGION`, SSE-S3) |
| `TF_VAR_OPERATOR_PRINCIPAL_ARN` | Your human IAM principal ARN. REQUIRED — without it no human can reach the cluster (RUNBOOK step 5b) |
| `SCAN_ALERT_EMAIL` | Email for alert notifications — kept a secret to stay out of the repo. See RUNBOOK Phase 0 step 6 for what the topic carries. |

### Repository variables (same page → Variables)
| Variable | Example |
|---|---|
| `AWS_REGION` | `us-east-1` |

### Environment (Settings → Environments)
Create an environment named **`production`** AND add yourself as a required
reviewer — this is REQUIRED, not optional (matches RUNBOOK Phase 0 step 4). An
environment with no required reviewers gates nothing: the terraform apply jobs
run `-auto-approve` under it, so skipping the reviewer means the first merge
builds VPC/EKS/RDS/NAT unattended. The app deploy job runs under it too, so
every app deploy waits on the same approval. Required reviewers are offered on
private repos only on GitHub Enterprise (public repos: any plan) — confirm the
checkbox exists before the first push.

## The OIDC roles (you're creating these)

Two roles, both trusting the GitHub OIDC provider
(`token.actions.githubusercontent.com`), scoped to this repo:

- **Terraform role** — broad permissions to create the infrastructure
  (VPC, EKS, RDS, IAM, etc.). This is powerful; its trust is scoped to this repo
  and to `terraform.yml` through `job_workflow_ref` (the JSON described under
  "Trust policies" below), because a branch or environment condition would not
  separate the roles and would break PR plans. Create the role with
  `MaxSessionDuration` 7200: the `apply` job requests a two-hour session
  (`role-duration-seconds: 7200`), and the assume fails if the role's maximum
  is lower.
- **App role** (shipped as `docs/app-ci-role-policy.json`) — narrower: ECR push on your repos (`ecr:PutImage`,
  `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`,
  `ecr:BatchCheckLayerAvailability` on the repo ARNs) PLUS the registry-level actions
  `ecr:GetAuthorizationToken` (docker login) and `ecr:DescribeRegistry` (deploy job)
  on `Resource: "*"` — these are registry-scoped and fail if granted only per-repo. Include
  `ecr:DescribeImages` (per-repo scoping fine) - the push step's idempotence
  guard needs it; without it the check silently falls through and re-runs hit
  ImageTagAlreadyExists again.
  PLUS `codebuild:StartBuild`/`codebuild:BatchGetBuilds`/`codebuild:StopBuild` scoped to the
  `sales-pipeline-argocd-refresh` project ARN and `logs:GetLogEvents` on its log
  group (the deploy job triggers an immediate ArgoCD refresh through it). Scope the
  StartBuild to THAT project only — StartBuild allows a buildspec override
  (arbitrary commands as the project's role), which is exactly why the refresher is
  a separate project with a minimal role bound to a dedicated RBAC group (get+patch on Applications in argocd only) instead of reusing the
  cluster-admin platform project. ON TOP of that scoping, add CodeBuild's own
  override lock — an explicit Deny on any StartBuild that carries a
  buildspecOverride at all:

  ```json
  {
    "Sid": "DenyBuildspecOverride",
    "Effect": "Deny",
    "Action": "codebuild:StartBuild",
    "Resource": "*",
    "Condition": { "Null": { "codebuild:source.buildspec": "false" } }
  }
  ```

  Notes: `codebuild:source.buildspec` supports ONLY the `Null` operator (it checks
  the field's existence, not its content), so this is a presence lock, not a value
  pin. Our workflows never pass `buildspec-override`, so the Deny never fires on
  legitimate runs. The statement ships in `docs/app-ci-role-policy.json` —
  attaching that file to the app role is what makes it real; this doc alone
  protects nothing. The same statement is in `docs/terraform-ci-role-policy.json`
  for the platform project. This is a LAYER, not a replacement for the weak-role
  design: the condition constrains this caller only, and buildspec isn't the only
  override surface (env-var and image overrides exist) — the minimal refresher role is still what contains the blast radius.

**Trust policies: scope each role to ITS workflow file** (the JSONs in
`docs/terraform-ci-role-trust.json` and `docs/app-ci-role-trust.json`; fill
`ACCOUNT_ID`, `OWNER_ID` and `REPO_ID` as quoted strings first). Three things
that do NOT work:
- `:environment:production` does NOT separate the roles — terraform `apply`,
  `platform-apply`, and app.yml `deploy` ALL use `environment: production`, so
  their OIDC tokens carry identical subs; a compromised step in app.yml could
  assume the near-admin Terraform role. The environment still matters as an
  APPROVAL gate — it just cannot be the identity boundary.
- `:ref:refs/heads/main` breaks PR plans (their sub is `...:pull_request`, not a
  branch ref).
- No DEFAULT sub can separate the workflows at all: GitHub's default formats
  (environment > pull_request > branch-ref) never contain the workflow file.

The differentiator is the `job_workflow_ref` claim, and since AWS's ~Jan-2026 STS
update it is validated NATIVELY: `token.actions.githubusercontent.com:job_workflow_ref`
is a first-class trust-policy condition key for the GitHub provider (alongside
`repository`, `repository_id`, `environment`, `actor_id`, `enterprise_id`, ...), per the IAM User
Guide's "Available keys for AWS OIDC federation" table. No GitHub-side setup — the
older sub-claim-customization workaround is no longer needed here. Each role's trust
just adds a `StringLike` on the key (shipped in the two JSONs):

- Terraform role → `shivamnambiar/sales-pipeline-final/.github/workflows/terraform.yml@*`
- App role      → `shivamnambiar/sales-pipeline-final/.github/workflows/app.yml@*`

Notes: the value is the BARE `owner/repo/.github/workflows/<file>@<ref>` path (no
`repo:` prefix — that's sub syntax); the `@*` covers main pushes AND PR plan refs
(`@refs/pull/N/merge`) in one condition. Both JSONs also pin `sub` as a two-value
`StringLike` — the legacy `repo:owner/repo:*` form and the immutable
`repo:owner@OWNER_ID/repo@REPO_ID:*` form GitHub emits for repos created after
July 15, 2026 (this repo's first push was 2026-09-08, so expect the latter) — plus
a `StringEquals` on `repository_id`, plus `aud`. Treat the `sub` pin as REQUIRED,
not optional hardening: reports on this STS update indicate OIDC trust policies
must still evaluate a `sub` condition — never drop it, including mid-rollout. One
more claim gotcha: `job_workflow_ref` points at the REUSABLE workflow file when a
job calls one — no job here does today, but a future reusable-workflow refactor
silently changes the claim value and fails the assume. Before pasting, decode a
token from a throwaway `id-token: write` step and compare `sub`,
`job_workflow_ref` and `repository_id` with the JSON.

**Roll out one role at a time.** Update the Terraform role's trust, run one PR
plan to confirm the assume works, then update the app role. Failure mode is
CLOSED: a typo'd key or value can never match, so that role denies ALL
AssumeRoleWithWebIdentity until corrected, and the other role is untouched.

## Platform stack runs in CodeBuild (private EKS endpoint)

The EKS endpoint is fully private, so the platform stack's helm/kubernetes providers
can't run from GitHub-hosted runners. The platform plan/apply jobs instead: zip
`terraform/platform-stack` + `terraform/modules/platform` → upload to
`s3://<state-bucket>/codebuild/platform-src.zip`
→ run the `sales-pipeline-platform` project (created by the infra stack, runs in
the private subnets) via the official `aws-actions/aws-codebuild-run-build` action,
which STREAMS the CodeBuild/CloudWatch log live into the GitHub Actions console —
so plan/apply output is visible step-by-step in the job, same experience as running
terraform on the runner. Note `disable-source-override: true` is REQUIRED: the
action defaults to pointing the build at the triggering GitHub commit, but this
project's source is the S3 zip (deliberately — no CodeBuild↔GitHub OAuth needed);
without that flag StartBuild fails on an invalid source version. The plan jobs also
persist the full log to a `plan.txt` artifact after completion (the action streams
to console but writes no file). The CI role needs
`codebuild:StartBuild/BatchGetBuilds/StopBuild` on the platform project only (the
refresh project is the app role's) + `logs:GetLogEvents`/`FilterLogEvents` (both in
the policy JSON — logs via the existing `logs:*`). Two things to know:
- **Ordering:** the CodeBuild project is created by the INFRA apply, so the very
  first platform plan/apply can only run after infra succeeds (the PR platform plan
  stays non-blocking for exactly this reason).
- **Grafana password comes from Secrets Manager, not GitHub.** The CodeBuild
  project defines `TF_VAR_grafana_admin_password` as a `SECRETS_MANAGER`-type
  environment variable pointing at the `sales-pipeline/grafana-admin` secret
  (created manually in RUNBOOK Phase 0 — the name AND the region are the
  contract). CodeBuild
  resolves it at build start; `codebuild:BatchGetBuilds` shows only the
  reference, never the value, and no `GRAFANA_ADMIN_PASSWORD` GitHub secret
  exists anymore. Rotation: `aws secretsmanager put-secret-value`, then re-run
  the platform apply (the helm upgrade applies it).

## Notes / things to know

- **App deploy is GitOps, not push-apply:** CI pins the image tags into
  `k8s/overlays/prod` (`kustomize edit set image`), commits that back to Git, and
  STOPS. ArgoCD — installed by Phase 1's platform-apply, its Application applied
  in Phase 2 — watches the repo and syncs the pinned tags. Git is the source of
  truth. The runner itself never runs `kubectl`; the refresh it triggers runs one
  `kubectl annotate` inside CodeBuild under that project's own minimal role. The
  deploy job needs `contents: write` + `id-token: write`, and no cluster RBAC
  entry for the app role.
- Trivy fails the build on CRITICAL/HIGH vulns (`exit-code: 1`, with
  `ignore-unfixed: true`). Loosen `severity` if it's too strict early on.
- ECR repos (`sales-pipeline-api`, `sales-pipeline-worker`) are created by the
  infra apply, so no app build can succeed before it. On a first setup push a
  fresh commit under `api/**`, `worker/**` or `app.yml` after the apply and leave
  its deploy job waiting until the overlay is bootstrapped (RUNBOOK Phase 3).

## Two Terraform stacks (infra + platform)

Terraform is split into two root modules with separate state — see
`terraform/README.md` for the split and the provider-bootstrap deadlock behind
it. The `terraform.yml` workflow applies BOTH stacks in order. After the infra `apply`
job succeeds, `platform-plan` and `platform-apply` run automatically (separate
state key `platform.tfstate`, `production` environment gate). The `needs: apply`
job chain enforces the ordering — platform can't start until the cluster exists,
because its providers read the live cluster via `data.aws_eks_cluster`.

The apply jobs re-plan at apply time instead of applying the PR's saved plan
(terraform.yml:141-145), because a stale plan can destroy resources a concurrent
change added; the tradeoff is possible unreviewed drift.

On a PR touching `terraform/**`, both stacks plan and post a summary comment:
infra via `plan`, platform via `platform-plan-pr`. Before the cluster exists that
platform plan is non-blocking and posts a cold-start comment.

## Operational gotchas (manifest/pipeline review)

- **Branch protection on `main`: DEFERRED for the demo phase (see docs/DESIGN.md
  for why).**
  GITHUB_TOKEN-authenticated pushes cannot be ruleset bypass actors (only roles,
  teams, registered GitHub Apps and, since May 2026, individual users can), and
  they trigger no workflow run at all. So DO NOT enable a require-PRs ruleset as
  things stand: it would block the deploy job's tag-pin push and every deploy
  dies at `git push`. The substantive protection is that the deploy job
  SELF-GATES, running `scripts/validate-manifests.sh` on the exact bytes it
  pushes.
  To enable protection later, the deploy push needs a GitHub App identity (App
  on the bypass list, `actions/create-github-app-token`), which also lifts the
  GITHUB_TOKEN trigger restriction. Make `k8s-validate` the required check —
  never app.yml's, which is path-filtered, so kustomization-only PRs would hang
  at "Expected - waiting" forever.
- **What the shared gate checks** (`scripts/validate-manifests.sh`, run by
  k8s-validate and by app.yml's deploy job): `kustomize build` the overlay and
  refuse an empty render; reject mutable tags (`latest|main|master|stable`),
  `@sha256:` digests and untagged images; reject unresolved `REPLACE_` tokens in
  the render and in `k8s/argocd/application.yaml`; then `kubeconform -strict`
  (k8s 1.36.0 plus the pinned CRDs-catalog SHA) on both.
  `VALIDATE_MANIFESTS_BUILD_ONLY=1` skips only the kubeconform step.
- **IMMUTABLE ECR + job re-runs:** because repos are `IMMUTABLE`, re-running a
  build job for a SHA whose image already pushed will fail at `docker push`
  (tag exists). Repointing an existing tag stays blocked by design (immutability), but plain job RE-RUNS are safe: the push step checks `ecr describe-images` and skips a tag that already exists (same SHA = same content). To deploy different content, push a new commit
  (new SHA) rather than re-running the old job.
- **KEDA queue-depth auth:** the ScaledObject references a `TriggerAuthentication`
  named `aws-sqs-auth` with `podIdentity.provider: aws`, so
  KEDA reads SQS via the KEDA operator's own IRSA role (provisioned in the security
  module as `<name>-keda-irsa` with `sqs:GetQueueAttributes`, and annotated onto the
  operator service account via `serviceAccount.operator.annotations`). This role is
  REQUIRED — without it the scaler can't reach SQS and the worker never scales from
  zero. Do not add a `roleArn` or an `identityOwner` pointing at the worker's own
  role: the worker's role is not the identity KEDA presents.
- **PrometheusRule ↔ Helm release name:** `ruleSelector` matches
  `release: kube-prometheus-stack`, so renaming the Helm release silently stops
  the ALERT RULES loading. PodMonitors are unaffected — `podMonitorSelector`
  renders empty, so they are selected regardless of label.

- **Run `terraform fmt` before first push:** the plan job runs `fmt -check`,
  which fails the build on any misalignment. Run `terraform fmt -recursive`
  locally first so the gate passes.
