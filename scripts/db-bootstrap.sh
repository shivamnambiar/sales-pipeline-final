#!/usr/bin/env bash
set -euo pipefail

SQL="scripts/db-bootstrap.sql"
DB_IDENTIFIER="${DB_IDENTIFIER:-sales-pipeline-db}"
NS="default"
MODE="${1:-}"
if [ -n "$MODE" ] && [ "$MODE" != "--verify-only" ]; then
  echo "usage: db-bootstrap.sh [--verify-only]" >&2
  exit 1
fi

echo "==> Preflight: checking required tools..."
MISSING=""
for tool in aws kubectl jq; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="${MISSING} ${tool}"
done
if [[ -n "${MISSING}" ]]; then
  echo "ERROR: required tools not found on PATH:${MISSING}" >&2
  exit 1
fi
if [ ! -f "$SQL" ]; then
  echo "ERROR: $SQL does not exist from $(pwd) - run this script from the repo root." >&2
  exit 1
fi

echo "==> Preflight: checking cluster connectivity..."
if ! API_ERR="$(kubectl version --request-timeout=10s 2>&1 >/dev/null)"; then
  echo "ERROR: kubectl cannot talk to the cluster API:" >&2
  echo "$API_ERR" >&2
  echo "Bring up the SSM tunnel first (RUNBOOK: Accessing the private cluster)." >&2
  exit 1
fi

echo "==> Reading the RDS endpoint and the managed master secret..."
if ! RDS_OUT="$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text)"; then
  echo "ERROR: aws rds describe-db-instances failed for $DB_IDENTIFIER." >&2
  echo "Confirm the infra apply completed, that AWS_DEFAULT_REGION is the region it ran in," >&2
  echo "and that your principal may call rds:DescribeDBInstances." >&2
  exit 1
fi
read -r DB_HOST DB_SECRET_ARN <<<"$RDS_OUT"
if [ -z "${DB_HOST:-}" ] || [ "$DB_HOST" = "None" ] || [ -z "${DB_SECRET_ARN:-}" ] || [ "$DB_SECRET_ARN" = "None" ]; then
  echo "ERROR: $DB_IDENTIFIER has no endpoint or no managed master secret yet - is it still creating?" >&2
  exit 1
fi
if ! MASTER_PW="$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text | jq -er .password)"; then
  echo "ERROR: could not read the master password from $DB_SECRET_ARN." >&2
  echo "An AccessDeniedException naming kms:Decrypt means your principal lacks decrypt on" >&2
  echo "the project key (alias/sales-pipeline); the secret is encrypted with it." >&2
  exit 1
fi
echo "    OK — endpoint $DB_HOST, secret read."

CONN="host=$DB_HOST port=5432 dbname=pipeline user=pipeline sslmode=require"
OVERRIDES='{"apiVersion":"v1","spec":{"tolerations":[{"key":"role","operator":"Equal","value":"bootstrap","effect":"NoSchedule"}]}}'

run_psql() {
  kubectl -n "$NS" run "$1" --rm -i --quiet --image=postgres:16 --restart=Never --pod-running-timeout=5m \
    --overrides="$OVERRIDES" \
    -- sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$1" -v ON_ERROR_STOP=1 -f -' psql "$CONN"
}

kubectl -n "$NS" delete pod db-bootstrap db-bootstrap-check --ignore-not-found >/dev/null

if [ "$MODE" != "--verify-only" ]; then
  echo "==> Running $SQL as the master user, from a pod on the bootstrap node group..."
  if ! { printf '%s\n' "$MASTER_PW"; cat "$SQL"; } | run_psql db-bootstrap; then
    echo "ERROR: psql stopped at the first failing statement (ON_ERROR_STOP=1); nothing after it ran." >&2
    echo "On a re-run the expected stop is 'role \"app_api\" already exists': the users exist" >&2
    echo "from the first run and every later statement is idempotent, so re-apply only the" >&2
    echo "statements after the one that failed, then run this script with --verify-only." >&2
    echo "A pod that never reached Running within 5m means either the postgres:16 pull" >&2
    echo "through the NAT is slow (re-run; the image is now cached) or the bootstrap node" >&2
    echo "group is not schedulable: kubectl -n $NS get events --sort-by=.lastTimestamp | tail" >&2
    exit 1
  fi
  echo "    OK — every statement in $SQL succeeded."
fi

echo "==> Verifying the grants the api and worker depend on..."
{ printf '%s\n' "$MASTER_PW"; cat <<'SQLCHECK'
SELECT rolname FROM pg_roles WHERE rolname IN ('app_api', 'app_worker') ORDER BY 1;
SELECT has_schema_privilege('app_api', 'public', 'CREATE') AS api_can_create;
SELECT defaclrole::regrole AS for_role, defaclobjtype, defaclacl FROM pg_default_acl ORDER BY 1, 2;
SQLCHECK
} | run_psql db-bootstrap-check
echo "==> Done. Expect both roles listed, api_can_create = t, and pg_default_acl rows for app_api"
echo "    granting app_worker on tables (r) and sequences (S)."
