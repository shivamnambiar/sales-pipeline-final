# Design — why this project is built the way it is

## What this is

A demonstration that one person can build production-grade AWS
infrastructure. The application — an API that accepts batches of sales
records and a worker that processes them — is deliberately tiny, because
the application is not the point. The pipeline pattern (API → S3 → queue →
worker → database) exists to give the infrastructure something real to do.
The data itself is synthetic sales records with deliberately malformed rows
mixed in, so the processing stage has real bad data to reject — that's what
powers the "debug a data anomaly" walkthrough.

## How data flows, and the tradeoffs behind it

The API does no processing. It stores the raw batch in S3, puts a small
pointer message on the SQS queue, records a job row in Postgres, and
returns a job ID immediately. The worker picks up the pointer, fetches the
batch from S3, validates and aggregates it, and writes results with
insert-if-not-exists semantics — so if a message is delivered twice (queues
do that), nothing double-counts. Payloads live in S3 rather than in the
queue because queue messages have small size limits; this is the standard
large-payload pattern.

A few choices here are deliberate tradeoffs, not defaults:

- **SQS over Postgres-as-a-queue.** Every option has a bill — Postgres
  charges polling/locking/cleanup code, SQS charges idempotency. Idempotency
  is the smaller fixed cost, and it's needed anyway for duplicate
  submissions. Postgres's atomicity advantage only holds for a
  single-database pipeline, which this outgrows once it fans out to S3.
- **Idempotency, deliberately paid where it's cheapest.** Results are keyed
  on `job_id` with `INSERT ... ON CONFLICT DO NOTHING`, result-write and
  status-update in one transaction. Redelivery can't double-count.
- **Graceful shutdown reinforces it.** The worker catches SIGTERM, finishes
  the in-flight job, and exits. If it's killed mid-job instead, the message
  is never deleted, so SQS redelivers it — and idempotency makes that safe.
  The two behaviors cover for each other.

## The defining decision: everything is private

No public load balancer, no public cluster endpoint, nothing
internet-facing. Humans reach the system through SSM tunnels. (This is
accurately described as a private, network-isolated backend — not
"Zero-Trust" in the strict sense, since Zero-Trust verifies identity
per-request rather than trusting network position.) This one choice
explains the strangest-looking parts of the design:

- The platform Terraform (the helm layer: Karpenter, KEDA, ArgoCD,
  monitoring) runs from CodeBuild *inside* the VPC, because installing
  things on the cluster requires reaching the cluster API, which only
  exists inside.
- Deploys are pull-based for the same reason. GitHub-hosted CI cannot
  reach the cluster to apply anything, so ArgoCD runs inside the cluster
  and pulls from the repo instead.
- The internet-egress saga. The original ambition was no NAT gateway at
  all, using VPC interface endpoints instead. Reality won: ArgoCD needs
  GitHub, the platform pulls public images, Karpenter talks to IAM — so
  NAT came back on. Only the ECR endpoints were kept, because they are the
  ones where the per-GB math actually saves money.

## How deploys work

Nothing deploys by hand. CI tests the code, builds the image,
security-scans it, and writes the image's git-SHA tag into the Kubernetes
overlay; ArgoCD syncs the cluster to match the repo (CI also pokes a small
in-VPC CodeBuild job so the sync happens immediately instead of on the next
poll). ECR is configured with immutable tags, so a pushed tag can never be
overwritten — what is running is provably the exact artifact that was
scanned, even though the reference is a tag rather than a digest. New scan findings on pushed images raise alerts (EventBridge →
SNS email, with a CloudWatch log trail).

## How it scales, and why those specific signals

The worker scales to zero when the queue is empty and comes back when work
arrives — **KEDA on SQS queue depth**, deliberately not CPU: the worker is
I/O-bound, so CPU would lie about real demand, and queue depth is the
honest signal. The API scales on CPU via HPA instead, which is the honest
signal for a request-serving web service. Never both autoscalers on one
workload.

Nodes are provisioned by **Karpenter** (not Cluster Autoscaler) across two
pools: on-demand for the API, and Spot for the worker — about 70% cheaper.
The worker is safe on Spot specifically because it's idempotent and SQS
redelivers on interruption: a node reclaim mid-job just triggers a
redelivery, not a lost or duplicated result. The database runs multi-AZ.

Two smaller decisions worth naming: API evolution uses **path-based
versioning** (`/v1`, `/v2`) rather than a CQRS-style read/write split — a
split is unnecessary at this scale, since reads are tiny lookups. And
cleanup is **declarative**, not a service: S3 lifecycle policies expire old
raw batches, SQS self-deletes processed messages — no hand-written cleanup
job to maintain.

## Observability: three pillars, deliberately split

Metrics are exposed by the services themselves, scraped by the in-cluster
Prometheus stack, and alert rules watch the numbers that matter: worker
job failures, record-rejection rate, p95 processing time, API error rate.
Traces flow through the OpenTelemetry collector into Tempo, viewed in the
same Grafana as the metrics. Logs go to CloudWatch, shipped by a Fluent
Bit daemonset — deliberately *not* Loki, because CloudWatch is managed
(no stateful log store to run) and reuses the KMS grant and log-group pattern
already established for VPC flow logs. The only VPC endpoints are the S3
gateway and two ECR interface endpoints, so log traffic rides the NAT. Cluster-native where it
unifies in Grafana, AWS-managed where it plugs into the existing
IAM/KMS/endpoint posture: right tool per concern. X-Ray was considered
and skipped — the collector could export to it with a config swap and no
application change, but running two trace backends for the same spans is
redundant.

## Security posture

No passwords anywhere: each workload gets its own AWS identity through the
cluster (IRSA), and the database uses IAM auth tokens instead of passwords.
The one password that must exist — the Postgres master user's, kept for
initial bootstrap and break-glass access — is generated and held by RDS
itself in Secrets Manager, never appearing in Terraform state. Network
policy is deny-everything-by-default with explicit allowances per
workload. CI authenticates to AWS via GitHub OIDC, with trust scoped to
this repo (by immutable ID) and the specific workflow file — a branch pin
would break PR plans — and the CI roles are explicitly denied the ability
to override CodeBuild buildspecs, so a compromised workflow can't repurpose
the in-VPC runner. Everything at rest is encrypted with a customer-managed
KMS key, except the CI-owned state bucket and the Grafana admin secret,
which predate that key and sit on AWS-managed keys.

## The limits are measured, not guessed

The API's 50,000-records-per-batch cap and the worker's 15MB S3 object
cap come from load-testing both services to their actual out-of-memory
points, then setting the guards below them.

The container sizes come from a second, sustained test,
`loadtest/plateau_test.py`, run against the docker compose stack: batches
of 10,000-50,000 records with 64-character regions and 60-character
order IDs, up to 200,000 records in flight against one API container,
until memory sets no new peak for five minutes. It peaked at 446 MiB for
the API and 106 MiB for the worker, and the 1Gi and 512Mi memory limits
sit above that with headroom. That headroom also has to cover
OpenTelemetry auto-instrumentation, which compose doesn't run. The worker
never saw its 15MB cap, because nothing sent through /jobs can reach it.
CPU (1 core API, 500m worker) is a judgment call, not a measurement.
Changing any of these limits means re-running the test under real load,
not re-guessing.

## Deliberately unfinished or deliberately deferred

Known and chosen, not forgotten:

- Region is supplied only by CI (the `AWS_REGION` repository variable). There
  is no tfvars file, so no value can silently shadow it.
- Branch protection on main is off on purpose: the pipeline itself commits
  the image-tag pin to main, so protecting the branch would block every
  deploy. Revisit only with a design that exempts the pipeline.
- **A public entry point (ALB + WAF)** was removed rather than never
  built: a private backend reached via `port-forward` has no internet
  surface to secure and costs less idle. It's a clean add-on, not a
  rework, if it's ever needed. A **custom domain + ACM cert** and
  **Cognito auth at the ALB** are both deferred alongside it — they're
  prerequisites of the public entry point, not independent gaps. The
  **live v1→v2 API routing demo** is deferred for the same reason: the
  versioning design already exists in the result model, only the ALB path
  rules to demo it live are missing.
- Three small gaps found by the load test are still open: an alert
  threshold that can never fire (WorkerProcessingSlow is set ~100x above
  observed reality), a failure counter that one rejection path never
  increments, and an order_id field that is validated but never stored.
