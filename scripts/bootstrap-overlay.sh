#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${1:?usage: bootstrap-overlay.sh <git_repo_url>}"

TF_DIR="terraform"
OVERLAY="k8s/overlays/prod/kustomization.yaml"
ARGO="k8s/argocd/application.yaml"
GATE="scripts/validate-manifests.sh"

echo "==> Preflight: checking required tools..."
REQUIRED_TOOLS=(terraform kubectl kustomize aws git jq)
MISSING=""
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="${MISSING} ${tool}"
done
if [[ -n "${MISSING}" ]]; then
  echo "ERROR: required tools not found on PATH:${MISSING}" >&2
  echo "Install the missing tool(s) and re-run." >&2
  exit 1
fi
echo "    OK — ${REQUIRED_TOOLS[*]} all present."

norm_url() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z+]+://##; s#^[^/@]*@##; s#:#/#; s#/+$##; s#\.git$##'
}

echo "==> Preflight: repository state..."
for path in "$TF_DIR" "$OVERLAY" "$ARGO" "$GATE"; do
  if [ ! -e "$path" ]; then
    echo "ERROR: $path does not exist from $(pwd)." >&2
    echo "Every path this script touches is relative - run it from the repo root." >&2
    exit 1
  fi
done
TARGET_REVISION="$(sed -nE 's/^[[:space:]]*targetRevision:[[:space:]]*([^[:space:]]+).*/\1/p' "$ARGO")"
if [ -z "$TARGET_REVISION" ]; then
  echo "ERROR: no targetRevision found in $ARGO." >&2
  exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "$TARGET_REVISION" ]; then
  echo "ERROR: HEAD is '$BRANCH' but $ARGO tracks '$TARGET_REVISION'." >&2
  echo "Bootstrap would push the resolved manifests to '$BRANCH' and then apply an" >&2
  echo "Application that syncs '$TARGET_REVISION', where the tokens are still" >&2
  echo "unresolved - a green dashboard over a broken render. Switch branch first." >&2
  exit 1
fi
REMOTE="$(git config --get "branch.${BRANCH}.remote" || true)"
if [ -z "$REMOTE" ]; then
  echo "ERROR: branch '$BRANCH' has no upstream remote, so the push below would" >&2
  echo "fail after both files had already been rewritten. Set one first:" >&2
  echo "  git push -u origin $BRANCH" >&2
  exit 1
fi
PUSH_URL="$(git remote get-url "$REMOTE")"
if [ "$(norm_url "$REPO_URL")" != "$(norm_url "$PUSH_URL")" ]; then
  echo "ERROR: the Application would watch $REPO_URL, but '$BRANCH' pushes to" >&2
  echo "$PUSH_URL. The manifests would land in one repo while ArgoCD synced the" >&2
  echo "other, and both halves would report success." >&2
  exit 1
fi
if ! LS_ERR="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$REPO_URL" 2>&1 >/dev/null)"; then
  echo "ERROR: git cannot read $REPO_URL:" >&2
  echo "$LS_ERR" >&2
  echo "Fix the URL, or give git credentials for it - a private repo you normally" >&2
  echo "reach over SSH will fail here if you passed the https:// form." >&2
  exit 1
fi
if ! PUSH_ERR="$(GIT_TERMINAL_PROMPT=0 git push --dry-run "$REMOTE" "$BRANCH" 2>&1 >/dev/null)"; then
  case "$PUSH_ERR" in
    *"[rejected]"*)
      echo "ERROR: $PUSH_URL rejects a push of '$BRANCH' as non-fast-forward:" >&2
      echo "$PUSH_ERR" >&2
      echo "Your branch is behind the remote. git pull first, then re-run." >&2
      exit 1
      ;;
    *)
      echo "ERROR: git cannot push to $PUSH_URL:" >&2
      echo "$PUSH_ERR" >&2
      echo "Read access was fine (ls-remote passed) but the push credential is not. This" >&2
      echo "script disables interactive prompts, so configure a credential helper or use" >&2
      echo "the SSH remote form. The script commits and pushes the resolved manifests" >&2
      echo "before it applies the Application, and a push that fails there leaves a local" >&2
      echo "commit that looks like the after-the-push state." >&2
      exit 1
      ;;
  esac
fi
echo "    OK — repo root, branch '$BRANCH', remote matches the Application's repoURL,"
echo "         push credential accepted (dry run; a ruleset is only tested by the real push)."
echo "         (Reachable by YOU; ArgoCD needs its own credential for a private repo.)"

echo "==> Preflight: checking cluster connectivity..."
if ! API_ERR="$(kubectl version --request-timeout=10s 2>&1 >/dev/null)"; then
  echo "ERROR: kubectl cannot talk to the cluster API:" >&2
  echo "$API_ERR" >&2
  echo "A timeout or connection refused means the SSM tunnel is not up (RUNBOOK:" >&2
  echo "Accessing the private cluster - kubeconfig at localhost:8443). Unauthorized" >&2
  echo "means the tunnel is fine and your principal has no access entry (RUNBOOK" >&2
  echo "Phase 0 step 5b). This script does NOT run update-kubeconfig - that would" >&2
  echo "overwrite the tunnel routing with the unreachable private hostname." >&2
  exit 1
fi
echo "    OK — cluster API reachable."

echo "==> Preflight: platform CRDs (the Application's resources need them)..."
REQUIRED_CRDS=(
  scaledobjects.keda.sh
  triggerauthentications.keda.sh
  podmonitors.monitoring.coreos.com
  prometheusrules.monitoring.coreos.com
  opentelemetrycollectors.opentelemetry.io
  instrumentations.opentelemetry.io
  nodepools.karpenter.sh
  ec2nodeclasses.karpenter.k8s.aws
  applications.argoproj.io
)
MISSING=""
for crd in "${REQUIRED_CRDS[@]}"; do
  if CRD_ERR="$(kubectl get crd "$crd" --request-timeout=10s 2>&1 >/dev/null)"; then
    continue
  fi
  case "$CRD_ERR" in
    *NotFound*) MISSING="$MISSING $crd" ;;
    *)
      echo "ERROR: the API did not answer whether CRD $crd exists:" >&2
      echo "$CRD_ERR" >&2
      echo "That is not a missing-CRD answer, so this is not the platform apply." >&2
      echo "Check the SSM tunnel and your access entry (RUNBOOK Phase 0 step 5b)." >&2
      exit 1
      ;;
  esac
done
if [ -n "$MISSING" ]; then
  echo "ERROR: missing CRDs:$MISSING" >&2
  echo "The platform apply has not completed - applying the Application now" >&2
  echo "would sync-degrade on unknown kinds until it converges. Run/finish the" >&2
  echo "platform apply first (RUNBOOK Phase 1), then re-run this script." >&2
  exit 1
fi
echo "    OK — all ${#REQUIRED_CRDS[@]} platform CRDs present."

tf() {
  VALUE="$(jq -er --arg key "$1" '.[$key].value' <<<"$OUTPUTS")" || {
    echo "ERROR: terraform output '$1' could not be read from the state." >&2
    exit 1
  }
  if [ -z "$VALUE" ]; then
    echo "ERROR: terraform output '$1' resolved to an empty string." >&2
    echo "An empty value substitutes cleanly and leaves no REPLACE_ token behind," >&2
    echo "so neither the gate below nor CI's own run would ever see it. Confirm the" >&2
    echo "infra apply completed, then re-run." >&2
    exit 1
  fi
  case "$VALUE" in
    *[[:space:]]*)
      echo "ERROR: terraform output '$1' contains whitespace; refusing to substitute." >&2
      echo "None of the nine values can legitimately hold any. A trailing CR is the" >&2
      echo "common case: jq resolved to a Windows jq.exe under WSL." >&2
      exit 1
      ;;
  esac
  printf '%s' "$VALUE"
}

echo "==> Reading Terraform outputs..."
OUTPUTS="$(terraform -chdir="$TF_DIR" output -json)"
REGION="$(tf region)"
SQS_QUEUE_URL="$(tf sqs_queue_url)"
RAW_BUCKET="$(tf raw_bucket_name)"
CLUSTER_NAME="$(tf cluster_name)"
KARPENTER_NODE_ROLE="$(tf karpenter_node_iam_role_name)"
API_IRSA_ROLE_ARN="$(tf api_role_arn)"
WORKER_IRSA_ROLE_ARN="$(tf worker_role_arn)"
DB_HOST="$(tf rds_endpoint)"
DB_NAME="$(tf db_name)"

echo "==> Substituting overlay + ArgoCD Application..."
sed -i \
  -e "s|REPLACE_AWS_REGION|${REGION}|g" \
  -e "s|REPLACE_SQS_QUEUE_URL|${SQS_QUEUE_URL}|g" \
  -e "s|REPLACE_RAW_BUCKET|${RAW_BUCKET}|g" \
  -e "s|REPLACE_CLUSTER_NAME|${CLUSTER_NAME}|g" \
  -e "s|REPLACE_KARPENTER_NODE_ROLE|${KARPENTER_NODE_ROLE}|g" \
  -e "s|REPLACE_API_IRSA_ROLE_ARN|${API_IRSA_ROLE_ARN}|g" \
  -e "s|REPLACE_WORKER_IRSA_ROLE_ARN|${WORKER_IRSA_ROLE_ARN}|g" \
  -e "s|REPLACE_DB_HOST|${DB_HOST}|g" \
  -e "s|REPLACE_DB_NAME|${DB_NAME}|g" \
  "$OVERLAY"

sed -i -E "s|^([[:space:]]*repoURL:[[:space:]]*).*|\\1${REPO_URL}|" "$ARGO"

echo "==> Validating the render with CI's own gate..."
if ! VALIDATE_MANIFESTS_BUILD_ONLY=1 bash "$GATE" "$(dirname "$OVERLAY")"; then
  echo "ERROR: the gate above refused the render. Nothing committed or pushed." >&2
  echo "On a FIRST setup the image tokens are the expected cause - app.yml cannot" >&2
  echo "pin them until these values are committed. RUNBOOK Phase 3, ORDERING, has" >&2
  echo "the sequence that breaks that tie." >&2
  exit 1
fi
echo "    OK — render accepted by the same gate CI runs."

echo "==> Dry-run: will the cluster accept the ArgoCD Application?"
if ! kubectl apply --dry-run=server --request-timeout=10s -f "$ARGO" >/dev/null; then
  echo "ERROR: the cluster refused the Application above. Nothing committed or pushed." >&2
  echo "Either helm_release.argocd has not run (no argocd namespace / no Application" >&2
  echo "CRD - finish the platform apply, RUNBOOK Phase 1), or your principal has no" >&2
  echo "access entry for it (RUNBOOK Phase 0 step 5b)." >&2
  exit 1
fi
echo "    OK — the cluster accepts the Application."

echo "==> Committing resolved manifests..."
git add "$OVERLAY" "$ARGO"
if git commit -m "bootstrap: resolve overlay values from terraform outputs"; then
  echo "    committed."
else
  echo "    nothing to commit - the resolved values are already in Git."
fi
git pull --rebase
git push

echo "==> Applying the ArgoCD Application (starts GitOps sync)..."
kubectl apply -f "$ARGO"

echo "==> Bootstrap complete. ArgoCD is now syncing k8s/overlays/prod from Git."
