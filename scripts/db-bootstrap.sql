-- IAM database authentication bootstrap.
--
-- Run ONCE against the RDS instance as the master user (`pipeline`), after the
-- instance is created and before the app pods start. This is a MANUAL step —
-- it can't live in Terraform (TF doesn't manage in-database objects) and
-- `scripts/bootstrap-overlay.sh` never touches the database.
--
-- WHY dedicated users instead of granting rds_iam to the master:
-- granting `rds_iam` to the master user DISABLES its password login — you'd lose
-- break-glass access and the managed master secret becomes dead weight. Instead
-- we create dedicated per-workload users with rds_iam + scoped grants, and keep
-- the master as a password break-glass account.
--
-- How to run: `bash scripts/db-bootstrap.sh` from the repo root with the SSM
-- tunnel up (RUNBOOK Phase 1.5). The DB SG admits only the private-subnet
-- CIDRs, so a laptop over NAT can NOT reach it (NAT is egress-only); the script
-- reads the endpoint and the managed master secret itself and feeds this file
-- to psql (`-v ON_ERROR_STOP=1 -f -`) from a postgres:16 pod on the bootstrap
-- node group. Not idempotent: a re-run stops at CREATE USER app_api.

CREATE USER app_api;
GRANT rds_iam TO app_api;

CREATE USER app_worker;
GRANT rds_iam TO app_worker;

GRANT CONNECT ON DATABASE pipeline TO app_api, app_worker;
GRANT USAGE ON SCHEMA public TO app_api, app_worker;

-- PG15+ revokes CREATE on schema public from non-owners. The API creates tables
-- in its FastAPI lifespan (CREATE TABLE IF NOT EXISTS) as app_api, so app_api
-- needs CREATE on the schema — without this it dies at startup with
-- "permission denied for schema public".
GRANT CREATE ON SCHEMA public TO app_api;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_api, app_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_api, app_worker;

-- Default privileges must be set FOR ROLE app_api, because the API creates the
-- tables — a bare ALTER DEFAULT PRIVILEGES only covers objects the CURRENT role
-- (master) creates, so the worker would get nothing on app_api's tables and hit
-- "permission denied" on UPDATE/INSERT. This grants the worker access to tables
-- app_api creates going forward.
--
-- PG16: ALTER DEFAULT PRIVILEGES FOR ROLE app_api requires the master to be a
-- (SET-able) MEMBER of app_api. PG16's CREATEROLE rework gives the creator only
-- ADMIN on new roles, not membership — so without this GRANT the three ALTER
-- statements below fail with "permission denied to change default privileges".
GRANT app_api TO pipeline;

ALTER DEFAULT PRIVILEGES FOR ROLE app_api IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_worker;
ALTER DEFAULT PRIVILEGES FOR ROLE app_api IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_worker;
ALTER DEFAULT PRIVILEGES FOR ROLE app_api IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_api;
