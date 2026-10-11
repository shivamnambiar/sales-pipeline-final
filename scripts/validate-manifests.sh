#!/usr/bin/env bash
set -euo pipefail

K8S_VERSION="1.36.0"
CATALOG_SHA="34cef0fc2698bbb611f475515e555a2d7ca85b6c"
OVERLAY="${1:-k8s/overlays/prod}"
APP="k8s/argocd/application.yaml"

echo "gate versions: $(kustomize version 2>/dev/null || echo 'kustomize ?') | $(kubeconform -v 2>/dev/null || echo 'kubeconform ?')"
echo "gate scope: structure only - 'kubectl apply --dry-run=server -k $OVERLAY' is the authoritative check this cannot perform"

SCHEMA_CACHE="${KUBECONFORM_CACHE:-${TMPDIR:-/tmp}/kubeconform-cache}"
mkdir -p "$SCHEMA_CACHE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUT="$TMP_DIR/manifests.yaml"

kustomize build "$OVERLAY" > "$OUT"
grep -q '^kind:' "$OUT" || { echo "GATE ERROR: rendered output has no resources - refusing a vacuous pass" >&2; exit 1; }

IMAGE_LINE='^[[:space:]]*-?[[:space:]]*image:[[:space:]]*'

if grep -nE "${IMAGE_LINE}.*:(latest|main|master|stable)[[:space:]]*$" "$OUT"; then
  echo "GATE ERROR: mutable image tag found above - pin to the immutable git-SHA tag CI produces. This repo relies on ECR tag immutability, NOT @sha256 digests - do not convert the overlay to digests." >&2
  exit 1
fi

if grep -nE "${IMAGE_LINE}.*@sha256:" "$OUT"; then
  echo "GATE ERROR: image pinned by digest above - this repo pins by immutable git-SHA tag, not by @sha256 digest." >&2
  exit 1
fi

untagged=$(sed -nE "s/${IMAGE_LINE}//p" "$OUT" \
  | sed -E 's/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//' \
  | awk -F/ 'NF > 0 && $NF !~ /:/ {print}' || true)
if [ -n "$untagged" ]; then
  printf 'GATE ERROR: untagged image (resolves to :latest) - pin to the immutable git-SHA tag CI produces: %s\n' "$untagged" >&2
  exit 1
fi

stray=$(grep -oE 'REPLACE_[A-Z_]+' "$OUT" | sort -u | tr '\n' ' ' || true)
if [ -n "$stray" ]; then
  echo "GATE ERROR: unresolved token(s) in the rendered overlay: $stray" >&2
  echo "Infra values come from scripts/bootstrap-overlay.sh, image tags from app.yml." >&2
  exit 1
fi

if [ -f "$APP" ] && grep -qE 'REPLACE_[A-Z_]+' "$APP"; then
  echo "GATE ERROR: $APP still holds a REPLACE_ token - bootstrap has not resolved and committed it." >&2
  exit 1
fi

if [ -n "${VALIDATE_MANIFESTS_BUILD_ONLY:-}" ]; then
  echo "build-only mode: overlay rendered, image tags and bootstrap tokens checked; kubeconform schema validation was NOT run"
  exit 0
fi

kubeconform \
  -strict \
  -summary \
  -cache "$SCHEMA_CACHE" \
  -kubernetes-version "${K8S_VERSION}" \
  -schema-location default \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CATALOG_SHA}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$OUT"

if [ -f "$APP" ]; then
  kubeconform -strict -summary \
    -cache "$SCHEMA_CACHE" \
    -kubernetes-version "${K8S_VERSION}" \
    -schema-location default \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/${CATALOG_SHA}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    "$APP"
else
  echo "note: $APP not found from $(pwd) - Application CR check skipped"
fi
