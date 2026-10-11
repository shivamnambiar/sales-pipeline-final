# App CI role policy

`app-ci-role-policy.json` is the permissions policy for the IAM role the app
workflow assumes via OIDC (`AWS_APP_ROLE_ARN`). Attach it to that role, and set
the role's trust policy from `app-ci-role-trust.json` (fill `ACCOUNT_ID`,
`OWNER_ID` and `REPO_ID` as quoted strings first).

There is nothing to replace in the policy itself: region and account are
wildcarded in every ARN, as in the Terraform policy's CodeBuild statements, and
the repository and project names come from the `name` default in
`terraform/variables.tf` (`sales-pipeline`). Change that default and these ARNs
must change with it.

## What each statement is for

- **ECRRegistry** (`Resource: "*"`): `ecr:GetAuthorizationToken` for the docker
  login in the build job, `ecr:DescribeRegistry` for the registry-ID lookup in
  the deploy job. Both are registry-level and fail if granted per-repository.
- **ECRPush** on the `sales-pipeline-api` and `sales-pipeline-worker` repository
  ARNs: the five push actions plus `ecr:DescribeImages`, which the push step's
  idempotence guard needs — without it the check silently falls through and a
  job re-run hits `ImageTagAlreadyExists`.
- **CodeBuildArgoCDRefresh** on the `sales-pipeline-argocd-refresh` project
  only: `StartBuild`/`BatchGetBuilds` for the refresh trigger, `StopBuild`
  because the CodeBuild action stops the build when the GitHub job is
  cancelled. Never widen this to `sales-pipeline-*`: StartBuild allows a
  buildspec override, and the platform project's role is cluster-admin.
- **DenyBuildspecOverride**: identical to the Terraform policy's statement, a
  presence lock on `codebuild:source.buildspec`. `.github/CICD_SETUP.md`
  explains why it is a layer, not the containment.
- **CodeBuildArgoCDRefreshLogs**: `logs:GetLogEvents` on the refresh project's
  log group, so the action can stream the build log into the job.

## What is deliberately absent

- No KMS actions. The ECR repositories are KMS-encrypted, but ECR encrypts and
  decrypts through a grant created when the repository is made, so pushers need
  no key permission.
- No ECR pull actions. Both images build `FROM python:3.12-slim` on Docker Hub.
- No EKS, `kubectl` or cluster RBAC. The deploy job pins tags into Git and
  stops; the refresh runs inside CodeBuild under that project's own role.

## Known caveats

- The CodeBuild action set was taken from the action's documented requirements,
  not observed from a real run. If the first deploy hits `AccessDenied`, read
  the action from the error and add it.
- Region and account wildcards mean the role could act on same-named resources
  in another region of this account. Pin both once the deployment region is
  fixed.
