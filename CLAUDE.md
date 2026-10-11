# sales-pipeline

Async ingestion pipeline on AWS: FastAPI accepts batches of sales records,
stores the raw batch in S3, queues a pointer message in SQS, and a worker
validates/dedupes/aggregates the batch into RDS. The app is deliberately
minimal — the infrastructure (fully private EKS, Terraform, GitOps) is the
product. Next milestone: the first real `terraform apply`.

## Map

- api/ — FastAPI ingest + status service
- worker/ — SQS consumer (worker.py); pure processing logic in processing.py
- terraform/ — root infra stack (modules: kms, network, security, data,
  cicd, cluster) plus platform-stack/ (helm platform, applied from in-VPC
  CodeBuild). modules/platform is loaded ONLY by platform-stack/, never by
  the root stack.
- k8s/ — kustomize base + prod overlay, synced by ArgoCD; CI pins images to
  immutable git-SHA tags
- loadtest/ — loadgen.py + configs (in-cluster calibration run, not yet
  executed) and plateau_test.py (the local compose run that sized the api
  and worker containers)
- scripts/ — validate-manifests.sh (CI's manifest gate),
  bootstrap-overlay.sh, db-bootstrap.sh (Phase 1.5 runner) + db-bootstrap.sql
- docs/ — DESIGN.md (the whys), the two CI role policy + trust JSONs, and a
  README per role
- .github/workflows/ — app.yml (test/build/scan/pin), terraform.yml,
  k8s-validate.yml
- RUNBOOK.md (root) — operations reference; smoke.sh (root) — e2e check
  against the compose stack

## Rules

- No comments in code, any language. If code seems to need a comment,
  restructure it until it doesn't. Tool directives such as shellcheck lines
  count as comments. The exceptions are operator documentation in non-code
  files, which you leave alone: `scripts/db-bootstrap.sql`, `.gitignore`, and
  the note in `k8s/overlays/prod/kustomization.yaml`.
- Shell access is a fixed allow list in `.claude/settings.json`. Without
  asking, you may run the read-only loop: `terraform fmt`, `terraform
  validate` and `terraform init -backend=false` (bare, or with
  `-chdir=terraform` / `-chdir=terraform/platform-stack`), `kustomize build`,
  `kubeconform`, `bash scripts/validate-manifests.sh`, the three test files
  by name (`cd api && python smoke_test.py`; `cd worker && python
  test_processing.py`; `python integration_test.py`), `jq`, `shellcheck`, and
  read-only git (`status`, `diff`, `log`, `show`). Use them: change something,
  validate it, and report what you ran and what it said. Denied outright,
  because AWS credentials exist on this machine and nothing you do may spend
  money or change real state: `terraform apply`, `destroy`, `import`,
  `state`, `taint`, `untaint`, `force-unlock`, `workspace`, `init
  -migrate-state`, `terragrunt`, `aws`, `eksctl`, `sam`, `cdk`, `kubectl`,
  `helm`, `curl`, `wget`, `ssh`, `scp`, `git push`, PowerShell, and the
  wrapper shells that could hide one of those (`powershell`, `pwsh`, `cmd`,
  `bash -c`, `sh -c`, `env`, `eval`). Bash is never how you change a file,
  either. Deny rules cover in-place editing (`sed -i`, `awk` with `inplace`,
  `system` or an in-program `>`, `patch`, `ed`, `vi`), the file movers (`cp`,
  `mv`, `rm`, `ln`, `touch`, `install`, `rsync`, `dd`, `truncate`, `tee`),
  the git commands that rewrite the working tree (`apply`, `am`, `restore`,
  `stash`, `checkout --`, `reset --hard`, `clean -f`, `rm`, `mv`) and the
  shells and privilege tools that could hide one of them (`sudo`, `exec`,
  `source`, `sh`, `zsh`, and command words that start with `$`, a backtick or
  a backslash). Claude Code itself checks `>`, `>>` and `tee` targets against
  the `Edit` rules. Reading is never blocked: `cat`, `head`, `grep`, `sed -n`
  and plain `awk` stay open. Wrappers that also serve reads (`xargs`, `find
  -exec`, `time`, `timeout`, `nice`, `nohup`, `command`) prompt, as does
  handing an interpreter a file or code (`python` with a flag or a path,
  `perl`, `node`, `bash <path>`, `./script`, `make`). Every file change goes
  through the Edit and Write tools, whose path rules are the enforcement, and
  that overrides any harness preference for editing with shell commands.
  `~/.aws` and the Terraform CLI config files are off limits too. Everything
  else goes to auto mode's classifier,
  which reads this file. Commands I want to see myself are in the `ask` list
  in `.claude/settings.json` and always prompt. When something prompts or is
  denied, say what you want to run and why. `init -backend=false` is allowed
  only as exact rules, with or without `-upgrade`, so no extra flag can
  re-enable the backend. Running the tests
  executes code you may have edited, so never put network or AWS calls in
  paths the tests exercise. Say plainly what you did not run.
- IMPORTANT: always start Claude Code from the repository root. Permission
  rules load only from the launch directory's `.claude/` folder, with no
  parent-directory fallback — start from a subdirectory and none of them
  apply. (`/cd` is disabled by a `Cd` deny rule; that restrains my slash
  command, not you.)
- The batch limits (API: 50,000 records per batch, worker: 15MB S3 object
  cap) were set by load-testing to the actual out-of-memory points. Don't
  change them without re-measuring under real load. The container memory
  limits (API 1Gi, worker 512Mi) come from loadtest/plateau_test.py; the
  same rule applies.
- Container images are pinned by CI to the build's git SHA as the tag, and
  those tags cannot be overwritten because ECR is configured
  image_tag_mutability = "IMMUTABLE". This is tag immutability, not digest
  pinning — don't "fix" the pipeline to use @sha256: digests. Never
  introduce a mutable tag like :latest. CI's `scripts/validate-manifests.sh`
  rejects mutable tags, digests and untagged images in the rendered overlay
  on every PR.
- The NAT gateway is permanent. `enable_nat` stays true: ArgoCD reaches
  GitHub, Karpenter reaches the IAM API, and platform images come from public
  registries, and none of those have VPC endpoints; only the ECR endpoints
  were kept. `single_nat = true` is a deliberate cost choice. DESIGN.md's
  "internet-egress saga" is the record — don't reopen it.
- There is no terraform.tfvars, on purpose. Each config value has exactly one
  home: four values come only from CI — `region` (GitHub variable
  `AWS_REGION`), `operator_principal_arn`, `tf_state_bucket` and
  `scan_alert_email` (GitHub secrets) — and the architectural values
  (`name`, `vpc_cidr`, `az_count`, `enable_nat`, `single_nat`) are defaults
  in `terraform/variables.tf`. Deny rules block creating any `*.tfvars` or
  `*.tfvars.json`. Don't add a default for `region` — its absence is what
  makes a misconfigured local run fail loudly; nothing enforces that one.
  RUNBOOK has the full map under "Where configuration values live".
- The files that define CI's checks are read-only to you: the three test
  files (worker/test_processing.py, worker/integration_test.py,
  api/smoke_test.py) and scripts/validate-manifests.sh. Propose test changes
  and I'll apply them. The workflow files are editable; I review every change
  with git diff.
- All markdown files in this project are read-only to you, including this
  one; an `Edit(**/*.md)` deny rule enforces it. Documentation is mine to
  write — if a doc needs changing, tell me what and why.
- You can read your own configuration but not change it: edit denies cover
  `.claude/` here, every `CLAUDE.md` and `CLAUDE.local.md` (this file
  included), the user-level `~/.claude` settings, instructions, rules,
  agents, skills, output styles and hooks, `~/.claude.json`, and `.mcp.json`.
  Read any of them whenever they're relevant. If one of these needs changing,
  tell me what and why. The only files you can't read are Terraform state,
  plan files, `crash.log`, and `~/.aws`.
- If a change touches CI, infra, or operations, check whether RUNBOOK.md,
  .github/CICD_SETUP.md, terraform/README.md, k8s/README.md and
  docs/terraform-ci-role-README.md still agree with it. When one has drifted,
  tell me which file, which lines, and what they should say.

## History

docs/DESIGN.md explains why the project is built the way it is — read it
before questioning an architectural choice. The raw build history is kept
outside the repo; if DESIGN.md doesn't answer a why, ask me. Going forward,
the reason for a notable choice goes in the conversation and the commit
message, nothing more.

## Commands

- Local e2e: `docker compose up` (postgres, localstack, api, worker), then
  `./smoke.sh`
- Pod sizing: `docker compose up -d`, then `python loadtest/plateau_test.py`
  (5-60 min, writes plateau_log.csv)
- Tests (self-contained, same invocation as CI): `cd api && python
  smoke_test.py` and `cd worker && python test_processing.py && python
  integration_test.py`
- Terraform check, from the repo root, one validate per stack:
  `terraform -chdir=terraform fmt -check -recursive`,
  `terraform -chdir=terraform validate`, and
  `terraform -chdir=terraform/platform-stack validate`. Each stack needs the
  one-time `init -backend=false` from RUNBOOK "Local workstation setup".
