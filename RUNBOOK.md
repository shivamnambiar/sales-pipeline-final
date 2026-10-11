# RUNBOOK — sales-pipeline lifecycle

The full sequence from nothing to a running system, and the steady-state loops
after. Three cadences: one-time bootstrap (manual, by hand), infra/platform (via
`terraform.yml`), and app (via `app.yml` + ArgoCD); the manifests are gated
separately by `k8s-validate.yml`.

The single most important ordering constraint: the **EKS cluster must exist before
the platform stack can plan or apply**, because the platform stack's providers read
the live cluster via `data.aws_eks_cluster`. That dependency drives the whole order.

---

## Local workstation setup (once per machine, no AWS involved)

Optional; it lets you run `terraform validate` locally before CI does. Costs
nothing and needs no AWS credentials — `-backend=false` skips remote state
and only downloads the providers:

```
export TF_VAR_region=us-east-1
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform/platform-stack init -backend=false
```

`region` has no default on purpose, so a local run without `TF_VAR_region` set
fails loudly rather than silently targeting the wrong region.

The k8s side, `scripts/validate-manifests.sh`, needs kustomize v5.4.3 and
kubeconform v0.6.7 (CI's pins) on PATH, and fetches CRD schemas over the network
unless the cache is warm. `VALIDATE_MANIFESTS_BUILD_ONLY=1` skips the kubeconform
step. What the gate checks: `.github/CICD_SETUP.md`.

---

## Where configuration values live

There is no `terraform.tfvars`. Each value has exactly one home:

- **`AWS_REGION`** — GitHub repository *variable*. The only source of the
  region, used for `TF_VAR_region`, the AWS credential region, and the state
  bucket's `-backend-config`.
- **`TF_VAR_OPERATOR_PRINCIPAL_ARN`** — GitHub *secret* (it contains the AWS
  account ID). See step 5b.
- **`TF_BACKEND_BUCKET`** — GitHub *secret*. The Terraform state bucket, passed
  both as `TF_VAR_tf_state_bucket` and as the backend config. `tf_state_bucket`
  is a required variable with no default, so a local `terraform plan` will
  prompt for it unless you export `TF_VAR_tf_state_bucket` too.
- **`SCAN_ALERT_EMAIL`** — GitHub *secret*, passed as
  `TF_VAR_scan_alert_email`. See Phase 0 step 6.
- **Everything else** (`name`, `vpc_cidr`, `az_count`, `enable_nat`,
  `single_nat`) — declared as defaults in `terraform/variables.tf`. These are
  architectural facts about this build, not per-deployment settings.
  `enable_nat` in particular is permanent: ArgoCD needs GitHub, Karpenter
  needs the IAM API, and platform images pull from public registries, none of
  which have VPC endpoints (see docs/DESIGN.md).

---

## Phase 0 — One-time manual bootstrap (before any CI runs)

These resources are created OUTSIDE Terraform on purpose: they're what CI itself
depends on, so the pipeline can't create them for itself (chicken-and-egg).

1. **Create the S3 state bucket in the region you will set as `AWS_REGION`**
   (`aws s3 mb s3://<bucket> --region <AWS_REGION>`; the backend init, the platform
   stack's remote-state read and the CodeBuild source all address it there). Enable
   versioning. Leave encryption at SSE-S3: the in-VPC CodeBuild role has no KMS
   grant, and the project key does not exist yet.
2. **Create the GitHub OIDC provider + two IAM roles** in the AWS account:
   - Terraform role (`AWS_TF_ROLE_ARN`) — manages all infra. Attach the policy in
     `docs/terraform-ci-role-policy.json` (replace `REPLACE_TF_STATE_BUCKET` first);
     see `docs/terraform-ci-role-README.md` for the scoping rationale and caveats
     (including why a first apply may hit one `AccessDenied` on an IAM action).
     Create it with `--max-session-duration 7200`: the `apply` job requests a
     two-hour session (`role-duration-seconds: 7200` in `terraform.yml`) because
     a first apply can run close to an hour, and a token that expires mid-apply
     leaves whatever was still being created outside state (see the watch list).
   - App role (`AWS_APP_ROLE_ARN`) — ECR push + app pipeline. Attach the policy in
     `docs/app-ci-role-policy.json` (nothing to replace: region and account are
     wildcarded, and the repo and project names come from the Terraform `name`
     default); see `docs/app-ci-role-README.md` for the scoping rationale.
   - both trust-scoped to this GitHub repo via OIDC. `docs/*-trust.json` already
     name `shivamnambiar/sales-pipeline-final`; fill `ACCOUNT_ID`, `OWNER_ID` and
     `REPO_ID` as quoted strings (`gh api repos/shivamnambiar/sales-pipeline-final
     --jq '{repo_id:.id,owner_id:.owner.id}'`). An unfilled `REPO_ID` denies every
     assume. Roll out one role, run one PR plan, then the other.
3. **Set GitHub repo secrets** (Settings → Secrets and variables → Actions):
   `AWS_TF_ROLE_ARN`, `AWS_APP_ROLE_ARN`, `TF_BACKEND_BUCKET`
   and the variable `AWS_REGION`. Every `aws` command in this runbook must run
   against that same region: `export AWS_DEFAULT_REGION=<AWS_REGION>`.
4. **Create a `production` environment** (Settings → Environments) **and add
   yourself as a required reviewer.** An environment with NO required reviewers
   gates nothing — the apply jobs run `-auto-approve` under it, so skipping the
   reviewer means your first merge auto-applies VPC/EKS/RDS/NAT unattended.
   Required reviewers exist on private repos only on GitHub Enterprise (public
   repos: any plan). Confirm the checkbox is offered before the first push; if it
   is not, make the repo public or do not merge to `main` until a gate exists.
5. **EKS endpoint is FULLY PRIVATE** (`eks_public_endpoint = false`, the default
   — see docs/DESIGN.md for why). No public access at all, not even IP-scoped.
   Two consequences before Phase 1:
   - **CI:** the infra stack runs from GitHub runners, but the platform stack runs
     inside an in-VPC CodeBuild project — you never run platform terraform from
     outside the VPC (mechanism: `.github/CICD_SETUP.md`).
   - **Humans:** your laptop can't reach the endpoint either. All human kubectl
     (Phase 1.5 psql, Phase 2 bootstrap, port-forward testing) goes through an SSM
     port-forward tunnel — see "Accessing the private cluster" below. This is why
     step 5b (operator_principal_arn) AND the SSM tunnel are both required.
5b. **REQUIRED: create the GitHub secret `TF_VAR_OPERATOR_PRINCIPAL_ARN`** set to
   your IAM user/role ARN, e.g. `arn:aws:iam::123456789012:role/YourRole`. There is
   no tfvars file — CI injects this as `TF_VAR_operator_principal_arn`. The CI role
   creates the cluster and becomes its only admin, so without an access entry for a
   human principal, every human-run step later (`bootstrap-overlay.sh`'s first
   preflight, the Phase 1.5 psql pod, port-forward testing) fails with
   `Unauthorized`. Unset/empty = CI-role-only access. Paste the IAM ARN
   (`aws iam get-role --query Role.Arn`), not the `arn:aws:sts::` session ARN.
   Phase 1.5, the tunnel and Phase 2's local `terraform init`/`output` also need,
   in this principal's own IAM policy: `rds:DescribeDBInstances`,
   `secretsmanager:GetSecretValue` on the RDS master secret, `kms:Decrypt` on
   `alias/sales-pipeline`, `ssm:StartSession`, `ec2:DescribeInstances`,
   `eks:DescribeCluster`, and `s3:GetObject` plus `s3:ListBucket` on the state
   bucket (an account admin has them all).
   **Do NOT set this to the CI role's ARN** — that role already gets an admin access
   entry via `enable_cluster_creator_admin_permissions`, and a duplicate entry fails
   the apply.
5c. **REQUIRED: create the Grafana admin secret in Secrets Manager** (before the
   first pipeline run — the platform CodeBuild project resolves it at build
   start, and plan/apply fail if it's missing):
   ```bash
   aws secretsmanager create-secret --name sales-pipeline/grafana-admin \
     --region "$AWS_REGION" --secret-string 'CHOOSE_A_STRONG_PASSWORD'
   ```
   The name `sales-pipeline/grafana-admin` and the region are a contract with the
   CodeBuild project definition — don't change one without the other. Plain string
   (not the console's key/value JSON), no `--kms-key-id`: the CodeBuild role has
   no KMS grant. To rotate later:
   `put-secret-value` with the new password, then re-run the platform apply.
6. **Add the `SCAN_ALERT_EMAIL` repo secret.** It is the only email subscription
   on the `sales-pipeline-image-scan-alerts` SNS topic, which carries ECR
   scan CRITICAL/HIGH findings, the DLQ alarm, and every Alertmanager alert
   except Watchdog and `severity: info`. Unset = no alert email at all. You must
   confirm the SNS subscription link AWS emails after apply — an unconfirmed
   subscription is indistinguishable from no alerting.
7. **Create the EC2 Spot service-linked role** — required in any account that has
   never launched a Spot instance, and idempotent. It is shared account state, so
   Terraform would fail where one already exists and delete it on destroy:
   ```bash
   aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
   ```
   Without it the worker's NodeClaims fail with
   `ServiceLinkedRoleCreationNotPermitted` and worker pods sit Pending while api
   pods run.
8. **Check EC2 quotas and the addon pins in `AWS_REGION`.** The first apply
   launches 16 On-Demand vCPUs (4 × c5.xlarge); a fresh account's default is 5,
   and the failure lands 15+ minutes in with VPC/NAT/EKS/RDS already billing.
   The first ArgoCD sync then adds Karpenter on-demand nodes for the api (about
   6 more vCPUs), so a quota of exactly 16 passes the apply but leaves the api
   Pending. Request 32 on `L-1216C47A` and wait for at least 22 before the first
   merge:
   ```bash
   aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query Quota.Value --output text
   aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 32
   for a in vpc-cni:v1.22.1-eksbuild.2 coredns:v1.14.3-eksbuild.2 kube-proxy:v1.36.0-eksbuild.7; do n=${a%%:*}; v=${a#*:}; echo -n "$n $v -> "; aws eks describe-addon-versions --kubernetes-version 1.36 --addon-name "$n" --query "addons[0].addonVersions[?addonVersion=='$v'].addonVersion" --output text; done
   ```
   An empty addon line means that pin in `terraform/modules/cluster/variables_cluster.tf`
   must move to a version the command lists.

Details in `.github/CICD_SETUP.md`. Nothing in CI works until these exist.

---

## Accessing the private cluster (required for every human kubectl step)

The EKS endpoint has no public access. To run kubectl from your machine, tunnel
through a node with SSM Session Manager (nodes have the SSM agent + the
AmazonSSMManagedInstanceCore policy; SSM traffic rides the NAT). Your laptop needs
the Session Manager plugin, a separate installer (`session-manager-plugin --version`):

```bash
NODE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=sales-pipeline" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
EKS_HOST=$(aws eks describe-cluster --name sales-pipeline \
  --query 'cluster.endpoint' --output text | sed 's|https://||')
aws ssm start-session --target "$NODE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=$EKS_HOST,portNumber=443,localPortNumber=8443"
```

Then in a second terminal, point kubeconfig at the tunnel:
`aws eks update-kubeconfig --name sales-pipeline`, edit the cluster `server:` to
`https://localhost:8443` and add `tls-server-name: <EKS_HOST>` (or set
`insecure-skip-tls-verify: true` for a throwaway demo session). kubectl now works.

## Phase 1 — Infra + platform provisioning (`terraform.yml`)

### IMPORTANT: split the very first commit (infra first, app second)

Skip this if the history is already on origin (`git status -sb` shows
`## main...origin/main`, clean — this repo): the initial push already fired all
three workflows before Phase 0 existed and they failed. Trigger terraform.yml
with a PR that changes a file under `terraform/**` and continue at step 5;
app.yml stays quiet on that merge by its own path filter.

On a fresh repo, push the Terraform first, let it apply, then push
the app code. `app.yml` is path-filtered to `api/**`, `worker/**` and its own
file, so a commit touching only `terraform/**` does not trigger it — which
matters because app.yml assumes the app IAM role and logs into ECR, neither of
which exists until infra has applied.

```bash
# 1. ONLY terraform + the terraform workflow. Don't `git add .github/` wholesale:
#    app.yml lists itself in its own path filter, so pushing it would trigger it.
git add terraform/ .github/workflows/terraform.yml .github/CICD_SETUP.md
git commit -m "infra: initial terraform + workflow"
git push
#    → terraform.yml runs. Work through Phase 1 until the cluster exists.

# 2. Everything else (app code, app.yml, k8s manifests, scripts).
git add .
git commit -m "app: initial application + manifests"
git push
#    → app.yml runs: images build and push. The deploy job waits for the
#      production review, then fails red at the gate until the overlay is
#      bootstrapped — see Phase 3, ORDERING.
```

After this, ordering no longer matters. On a fresh repo the first push may need
`git push -u origin main`.

### The workflow runs

5. **Open a PR** touching `terraform/**` (steady-state flow — first bootstrap can
   equally be a direct push to main; plan and apply run on push too):
   - `plan` (infra) → posts plan summary comment + uploads plan artifact
   - `platform-plan-pr` → on the FIRST run this hits the cold-start case (no cluster
     yet), posts the "expected, non-blocking" comment. Correct — nothing to plan
     against yet.
6. **Review the infra plan artifact, then merge to main.** On merge:
   - `apply` (infra) — `production` gate → APPROVE → creates VPC, EKS, IAM, KMS,
     RDS (IAM auth, no proxy), SQS, S3, VPC endpoints.
   - `platform-plan` (`needs: apply`) — cluster now exists, plans successfully.
   - `platform-apply` (`needs: platform-plan`, `production` gate) → APPROVE →
     installs Helm releases: Karpenter, ArgoCD, kube-prometheus-stack, Tempo,
     Fluent Bit, KEDA, metrics-server, OTel operator.

After Phase 1: cluster + operators running, but NO app deployed yet and the K8s
manifests still hold unresolved `REPLACE_` tokens — so `k8s-validate` is red on
main and on every PR (it has no path filter) until the first human push or PR
after bootstrap lands (CI's pin push is by GITHUB_TOKEN, which starts no workflow).

---

## Phase 1.5 — REQUIRED: create the IAM DB users (`scripts/db-bootstrap.sh`)

Before app pods start, the dedicated IAM DB users (`app_api`, `app_worker`) must
exist, or the app's IAM-auth connections fail with "role does not exist" and the API
also fails on `CREATE TABLE` without the schema grant. This is a MANUAL, one-time step
(Terraform doesn't manage in-database objects).

The SQL runs as the master user (`pipeline`) from a pod INSIDE the VPC — the DB SG
admits only the private-subnet CIDRs (a laptop over NAT will NOT reach it). At this
point every node is tainted (`role=bootstrap`/`role=monitoring`) and the untainted
Karpenter NodePools don't exist until the first sync, so a bare `kubectl run` pod
stays Pending forever. With the SSM tunnel up and `AWS_DEFAULT_REGION` exported:

```bash
bash scripts/db-bootstrap.sh        # DB_IDENTIFIER=<name> overrides sales-pipeline-db
```

It reads the endpoint and the RDS-managed master secret itself (needs the 5b
permissions), runs `scripts/db-bootstrap.sql` from a `postgres:16` pod with the
bootstrap toleration (`psql -f -`, `ON_ERROR_STOP=1`; the password never enters
the pod spec), then prints the roles, `api_can_create = t` and the
`pg_default_acl` rows granting `app_worker`. The SQL is not idempotent: a re-run
stops at `CREATE USER app_api`; apply what a partial run skipped by hand, then
`bash scripts/db-bootstrap.sh --verify-only`.

## Phase 2 — One-time overlay bootstrap (`scripts/bootstrap-overlay.sh`)

Manual-by-design: a one-time op, deliberately NOT wired into a runs-every-change
workflow (that would couple infra-apply to manifest-rewriting).

Prereqs — the script refuses on every one of these before it changes a file:
- Run it from the REPO ROOT, on `main`: every path it uses is relative, and it
  compares your branch to the Application's `targetRevision`.
- Tools on PATH: `terraform`, `kubectl`, `kustomize`, `aws`, `git`, `jq`
- A WORKING kubectl context: the SSM tunnel up and kubeconfig at localhost:8443
  (see "Accessing the private cluster")
- AWS credentials configured in the shell (for the S3 backend read + EKS auth)
- Both Terraform stacks applied: infra (so outputs exist) AND platform (so ArgoCD
  exists to receive the Application)
- The BACKEND-CONFIGURED `terraform init` already run in `./terraform` (MANUAL —
  the script never inits, to keep the backend bucket out of the script and shell
  history). Its flags are in `terraform/README.md`; the `-backend=false` init under
  "Local workstation setup" cannot serve `terraform output`.
- Git identity, push access (checked with a dry-run push, prompts disabled — a
  credential helper or the SSH remote) and an upstream for `main`

7. **Run `./scripts/bootstrap-overlay.sh <git_repo_url>`.** It:
   - checks the prereqs above, and that `<git_repo_url>` is readable, is the repo
     `main` actually pushes to, and accepts your push credential (dry run)
   - verifies kubectl can already reach the cluster; it does NOT run
     update-kubeconfig, which would overwrite the tunnel routing
   - requires nine CRDs — the eight the render uses, plus ArgoCD's own — else
     refuses (the platform apply has not finished)
   - reads all nine Terraform outputs from ONE `terraform output -json` snapshot
     and refuses any that is empty (never `init`/`plan`/`apply`)
   - substitutes the values into the overlay `kustomization.yaml` + the ArgoCD
     Application
   - runs `scripts/validate-manifests.sh` on the render — CI's own gate, minus the
     kubeconform step
   - server-side dry-runs the Application, so a missing `argocd` namespace, a
     missing CRD or a missing access entry is caught before anything is pushed
   - commits, rebases and pushes the resolved manifests
   - applies the ArgoCD Application → ArgoCD starts watching `k8s/overlays/prod`

   Re-running it is safe. A failure leaves one of four states:
   - during the preflights or the Terraform read → working tree untouched
   - at the gate or the dry-run → both files rewritten and UNCOMMITTED; undo with
     `git checkout -- k8s/overlays/prod/kustomization.yaml k8s/argocd/application.yaml`
   - at the rebase or the push → tree clean, commit made but NOT on the remote
     (`git log --oneline origin/main..HEAD` is non-empty): push first, do NOT
     apply the Application — the remote overlay still holds `REPLACE_` tokens
   - after the push (`origin/main..HEAD` empty) → the only step outstanding is
     `kubectl apply -f k8s/argocd/application.yaml`

   Once that apply has run there is no Git-reversible undo — see Rollback.

   **REQUIRED for private repos:** ArgoCD's repo-server needs credentials to fetch a
   private `repoURL`. The bootstrap script does NOT provision one, so if your repo is
   private, Phase 2 will complete "successfully" and then sync sits in a repo-access
   error (ComparisonError) with nothing syncing. Before/after applying the Application,
   add a repo credential — e.g. `argocd repo add <repoURL> --username <user>
   --password <token>`, or apply a `argocd.argoproj.io/secret-type: repository` Secret
   in the `argocd` namespace with the URL + token. If the repo is PUBLIC, skip this.

---

## Phase 3 — App image resolved (triggered by the first push)

On a first setup the app pipeline needs a push of its own after the infra apply:
a commit to `main` that touches `api/**`, `worker/**` or
`.github/workflows/app.yml` (app.yml's path filter). Nothing else starts a build,
and a run from before the apply has no images to pin. In steady state app.yml
runs before bootstrap:
8. **`app.yml` runs:**
   - test → build images → Trivy scan → push to ECR tagged with the commit SHA
   - the **deploy** job waits for the `production` review first. On a first
     setup LEAVE it waiting until (ii) below has been pushed.
   - `kustomize edit set image` pins the real registry + SHA into the overlay's
     `images:` block
   - re-runs `scripts/validate-manifests.sh` on the pinned overlay, then commits
     and pushes. No `kubectl apply`.
   - triggers the `argocd-refresh` CodeBuild (`continue-on-error`): its `kubectl
     annotate` fails until the Application exists, and the job finishes green
     with a `::warning`

ORDERING, first setup only: the gate rejects any unresolved `REPLACE_` token, so
the deploy job stops at it and never pins, while bootstrap's own gate run stops on
the image tokens and never applies. Neither can go first. Break the tie from the
bootstrap side:

- **(i)** `git pull` if `main` is behind origin (step 6's merge) — the script
  refuses a non-fast-forward before touching a file — then run Phase 2. It
  resolves both files and stops at the gate, listing the image tokens. Both
  files are now rewritten in your working tree, uncommitted.
- **(ii)** Commit and push exactly those two files:
  ```bash
  git add k8s/overlays/prod/kustomization.yaml k8s/argocd/application.yaml
  git commit -m "bootstrap: resolve overlay values from terraform outputs"
  git push
  ```
  `k8s-validate` stays red on this push — the image tokens are still there.
- **(iii)** Approve the pending `production` review on the **deploy** job of the
  app run that pushed the images (Actions → that `app` run → Review deployments).
  It checks out `main`, so it picks up (ii); it pins `${{ github.sha }}`, the SHA
  that was built and scanned; the gate now passes; it commits and pushes the pin.
  If that job already ran and failed on the tokens (no required reviewer),
  "Re-run failed jobs" instead: only deploy re-runs, it keeps the run's
  `github.sha`, and it waits for the review again if one exists. Re-runs are
  allowed for 30 days after the run; after that, push a fresh commit under
  `api/**`, `worker/**` or `.github/workflows/app.yml` and use its run.
- **(iv)** `git pull` — required; the script refuses a non-fast-forward — then run
  Phase 2 again. Nothing is left to substitute or commit, so it applies the
  Application. Signals: (iii)'s deploy job green, `deploy: pin images to <sha>`
  at `origin/main`, and `kubectl -n argocd get application sales-pipeline` →
  Synced/Healthy. `k8s-validate` does NOT run on CI's GITHUB_TOKEN push; its
  newest run stays (ii)'s red one until your next push or PR.

Every later run needs only the deploy approval — app.yml does the rest unaided.

If the run can no longer be re-run (older than 30 days), pin by hand instead of
(iii)–(iv) — ONLY if `aws ecr describe-images --repository-name sales-pipeline-api
--image-ids imageTag=<sha>` succeeds (and for `-worker`): with no image, every gate
passes and both Deployments sit in ImagePullBackOff. Otherwise push a fresh app commit.
- **Which SHA:** the one app.yml's run pushed images with — the Actions run title,
  or `aws ecr list-images --repository-name sales-pipeline-api`. NOT
  `git rev-parse HEAD`: a terraform merge from step 6, or step 2's own commit,
  advances HEAD past the last commit that built an image.
- **Which registry:** `terraform -chdir=terraform output -raw ecr_api_repo_url` and
  `ecr_worker_repo_url`.
- Then `cd k8s/overlays/prod && kustomize edit set image
  REPLACE_ECR_API_REPO=<api_repo_url>:<sha>
  REPLACE_ECR_WORKER_REPO=<worker_repo_url>:<sha>`, commit that file, push, and run
  Phase 2 again. Git stays the source of truth, but a hand pin is not CI's
  scanned-artifact guarantee (docs/DESIGN.md); the next app.yml run restores it.

9. **Bootstrap (Phase 2) applies the ArgoCD Application → ArgoCD starts syncing**
   the now-fully-resolved `k8s/overlays/prod`. `selfHeal: true` keeps it pinned to
   Git thereafter.

---

## Steady state (after first setup)

- **Infra/platform change** → PR (both stacks plan, reviewable) → merge → gated apply.
- **App change** → push → approve the deploy job → CI builds + pins tag in Git → ArgoCD syncs.
- **Rollback** → `git revert` the offending commit → ArgoCD syncs back. `selfHeal`
  prevents manual drift from sticking. App and image-pin commits ONLY: reverting
  the Phase 2 bootstrap commit feeds the `REPLACE_` placeholders back into the
  branch a live `prune`/`selfHeal` Application is tracking, so both Deployments
  roll onto a ConfigMap of literal placeholder strings, both ServiceAccounts lose
  their IRSA annotation, and the EC2NodeClass loses its role and both discovery
  tags. Fix a bad bootstrapped value with a FORWARD commit. Removing the
  Application is teardown, not rollback — there is no non-destructive undo for it.
- **Teardown** → in this order:
  1. `kubectl -n argocd delete application sales-pipeline` — NOT optional. Its
     cascade finalizer deletes the NodePools while ArgoCD and Karpenter are both
     still running, the only window in which Karpenter's instances get drained.
  2. Wait for `kubectl get nodeclaims -A` to come back empty.
  3. Empty the raw bucket and both ECR repositories, then `terraform destroy` the
     infra stack (`deletion_protection=false`, `skip_final_snapshot=true` keep the
     DB side clean; a non-empty bucket or repo fails the destroy).

  The platform stack needs no destroy: everything it creates is in-cluster (Helm
  releases plus one Role/RoleBinding), so it goes with the cluster and only its
  state is left stale. Skipping step 1 fails quietly — nothing terminates the
  Karpenter instances, so the infra destroy dies on DependencyViolation for the
  private subnets and the node SG, with the control plane already gone. Recovery:
  terminate the instances tagged `karpenter.sh/nodeclaim` by hand, then re-run.

---

## Cost note

The billable always-on pieces are the EKS control plane and the RDS
instance (IAM auth, no proxy). NAT is ON permanently (ArgoCD/Karpenter/image pulls
need egress — see docs/DESIGN.md), so budget the NAT gateway. `plan`
is read-only (≈free); `apply` provisions the billable resources. The tightest-cost
play: provision → demonstrate → `destroy` in one sitting.

---

## First-apply watch list (expected, not bugs)

- If **platform-apply stalls near five minutes and then fails** on
  `helm_release.kube_prometheus_stack`, check the admission-webhook hook Jobs
  first (`kubectl -n monitoring get jobs | grep admission`): FailedScheduling on
  the `role=bootstrap`/`role=monitoring` taints means the
  `prometheusOperator.admissionWebhooks.patch.*` placement is wrong. The generic
  Helm error names neither the Job nor the taint, and `helm_release.tempo` never
  runs after it.
- api and worker pods sit Pending on first sync: both select a `capacity` label
  only Karpenter nodes carry, and the managed node groups are tainted
  role=bootstrap/monitoring. Expected on apply day. BUT api Running while worker
  stays Pending is NOT the expected case — that is Spot failing, most likely the
  service-linked role from Phase 0 step 7:
  `kubectl get events -A --field-selector type=Warning | grep ServiceLinkedRole`.
  KEDA scales the worker to zero when idle, so check while a batch is queued.
- Karpenter's pricing fetch rides the permanent NAT and should SUCCEED. An error
  there is an egress problem (SG/NAT), NOT an expected fallback — do not dismiss it.
- Confirm Tempo's Service ports:
  `kubectl -n monitoring get svc tempo -o jsonpath='{.spec.ports[*].port}'` —
  expect 3200 (Grafana's datasource) and 4317 (the collector's export).
- `apply` red on `aws_eks_node_group` with `AsgInstanceLaunchFailures /
  VcpuLimitExceeded`: the account's On-Demand vCPU quota (Phase 0 step 8), not
  code. Request the increase and re-run the failed apply job; state was saved.
- `apply` red with `ExpiredToken` late in the run: the job's credential
  (`role-duration-seconds` in `terraform.yml`, two hours) ran out. The final
  state write and the lock release failed on the same token, so whatever was
  still being created (RDS and EKS build in parallel) exists in AWS but not in
  state, and `terraform.tfstate.tflock` is left in the bucket. Delete that lock
  object (never `terraform.tfstate`), delete the orphans by hand (`aws rds
  delete-db-instance --skip-final-snapshot`, `aws eks delete-nodegroup`, `aws
  eks delete-cluster`) and wait for each describe to return NotFound. Do NOT
  "Re-run failed jobs": a re-run executes the failed run's workflow file with
  the same duration. Raise the role's `MaxSessionDuration` and
  `role-duration-seconds` together, merge that as a new PR, and approve its
  apply.
- api CrashLoopBackOff with `role "app_api" does not exist` = Phase 1.5 did not
  run (`bash scripts/db-bootstrap.sh`; pods recover on restart). Both Deployments
  ImagePullBackOff after a green sync = a hand pin of a SHA with no image.
- After a red `platform-apply`, `helm list -A -a` through the tunnel before
  re-running. A failed install is retried as an upgrade by the next apply; a build
  killed by CodeBuild's 45-minute timeout leaves `pending-install` (clear with
  `helm uninstall <release> -n <ns>`) and an orphaned lock object,
  `platform.tfstate.tflock`, next to the state
  (`aws s3api list-objects-v2 --bucket "$TF_BACKEND_BUCKET" --prefix platform.tfstate`
  lists both). Delete only the lock:
  `aws s3api delete-object --bucket "$TF_BACKEND_BUCKET" --key platform.tfstate.tflock`;
  `platform.tfstate` itself is the state.
- Grafana's control-plane dashboards (scheduler, controller-manager, etcd,
  kube-proxy) are empty on purpose: EKS exposes none of those targets, so their
  scrapes and default alerts are disabled in the platform values.
