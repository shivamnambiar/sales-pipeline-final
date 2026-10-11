# Kubernetes Manifests — Kustomize

Structured as Kustomize `base/` + `overlays/prod/` from the start. The layout is
final; the value-dependent fields hold `REPLACE_` placeholders until Terraform
emits real outputs (filled in ONE place — the overlay).

## REPLACE_ value substitution — overlay is the single source

Two categories, two mechanisms:

**1. Infra-derived, one-time (bootstrap).** `REPLACE_AWS_REGION`,
`REPLACE_SQS_QUEUE_URL`, `REPLACE_RAW_BUCKET`, `REPLACE_CLUSTER_NAME`,
`REPLACE_KARPENTER_NODE_ROLE`, `REPLACE_API_IRSA_ROLE_ARN`,
`REPLACE_WORKER_IRSA_ROLE_ARN`, `REPLACE_DB_HOST`, `REPLACE_DB_NAME`,
`REPLACE_GIT_REPO_URL`.
Run `scripts/bootstrap-overlay.sh <git_repo_url>` after BOTH stacks apply (infra +
platform, so ArgoCD is installed): substitutes from Terraform outputs → runs CI's
gate on the render → server-side dry-runs the Application → commits → pushes →
applies it. Re-running is safe; it is not atomic, and RUNBOOK Phase 2 has the
recovery for each of the four places it can stop (a failed push leaves a local
commit; `git log origin/main..HEAD` tells that state from "after the push").
It substitutes in just TWO files:
- `k8s/overlays/prod/kustomization.yaml` — the SINGLE source. Its
  configMapGenerator literals + patch values hold these, and kustomize
  propagates them into the base manifests via `replacements` (ScaledObject
  queue/region, EC2NodeClass role + discovery tags) and JSON6902 `patches` (the
  IRSA annotations). You never edit the
  base files — kustomize fans the values out from the overlay.
- `k8s/argocd/application.yaml` — the ONLY file outside the overlay, because the
  ArgoCD Application is applied separately (not part of the kustomize build), so
  it can't receive an overlay value. Just its repoURL.

**2. Per-build image tags (CI).** app.yml pins both images with `kustomize edit set
image`. `REPLACE_ECR_*_REPO` survive only as the `images[].name` match keys; the
rendered build carries no REPLACE_ token at all. app.yml runs before bootstrap in
steady state only — on the FIRST setup neither can go first (RUNBOOK Phase 3,
ORDERING).

## API availability: rolling strategy + PDB + HPA (the interplay)

The goal: never serve on fewer than 2 API pods, and during a deploy always bring
up a replacement BEFORE removing an old pod (briefly N+1, never N-1). This needs
THREE settings that must agree — they govern different events:

- **Rolling deploys** (new image): Deployment `strategy.rollingUpdate`
  `maxUnavailable: 0` + `maxSurge: 1`. This is what gives "replacement ready
  before eviction" — it's NOT the PDB's job. PDBs don't govern rollouts.
- **Voluntary disruptions** (node drain, Karpenter consolidation): PDB
  `minAvailable: 2`. Keeps 2 serving during a drain. NOTE: a PDB that forbids ALL
  disruption (`maxUnavailable: 0` or `minAvailable` == replica count) DEADLOCKS
  node drains — Karpenter can't evict anything. The PDB must keep a FLOOR below
  the running count, not forbid eviction.
- **Replica count**: HPA `minReplicas: 3` (and Deployment `replicas: 3` initial).
  Critical: the PDB floor (2) must be STRICTLY LESS than the running count (3) or
  drains deadlock — with 3 running and minAvailable 2, exactly one pod can be
  evicted at a time, so node lifecycle proceeds while never dropping below 2.

The worker PDB stays `maxUnavailable: 1` (not a minAvailable floor) because KEDA
scales it to zero — a strict floor would fight scale-to-zero.

## NetworkPolicy: why API ingress is monitoring-only

`allow-api-ingress` scopes port 8000 to the `monitoring` namespace only — same
pattern as the worker metrics policy. This is deliberate, not a gap:

- **Prometheus scraping** `/metrics` on 8000 comes from `monitoring` — allowed.
- **Actual API access** (`/jobs` endpoints) is via `kubectl port-forward` over
  the EKS control plane, NOT an ingress controller (the private-backend design
  has none). Port-forward traffic arrives through the kubelet/API-server path; it
  is NOT pod-sourced and is NOT governed by NetworkPolicy. It's gated instead by
  Kubernetes RBAC (`pods/portforward`) + IAM. So there is no ingress-controller
  rule to add, and the two access paths are controlled by two different layers:
  network policy for in-cluster (Prometheus), RBAC for port-forward.
- **No in-cluster pod-to-pod caller** of the API exists by design (the worker
  consumes from SQS, not the API). If one is added later, it needs its own allow
  rule.

## Metrics discovery chain (cross-namespace PodMonitors)

PodMonitors live in `monitoring` (with Prometheus) but the pods they scrape live
in `sales-pipeline`. Three things must line up, or scraping silently returns zero
targets:

1. **PodMonitor objects discovered:** they're co-located with Prometheus in
   `monitoring`, which Prometheus searches by default. (`podMonitorSelectorNilUsesHelmValues=false`
   in the platform module means they're selected regardless of label scheme.)
2. **Pods scraped cross-namespace:** each PodMonitor sets
   `spec.namespaceSelector.matchNames: [sales-pipeline]`. WITHOUT this, an
   omitted selector means "only the PodMonitor's own namespace" — so it would
   look for app pods in `monitoring`, find none, and scrape nothing silently.
3. **Port names match:** the API pod's `http` port and the worker's `metrics`
   port (9100) match the `podMetricsEndpoints[].port` names.

## Base structure: app/ vs platform/ (namespace isolation)

`base/` is split because a single `namespace:` directive can't serve both
namespaced app workloads and resources that belong elsewhere:

- `base/app/` — the app workloads. Its kustomization sets
  `namespace: sales-pipeline`, applied to everything here (deployments, SAs,
  ScaledObject, Instrumentation, PDBs, NetworkPolicies).
- `base/platform/` — platform glue that must NOT be forced into the app
  namespace. NO namespace directive here; each resource self-namespaces:
  the OTel collector → `opentelemetry`, PodMonitors + PrometheusRule →
  `monitoring` (where Prometheus runs, so its selector finds them), and the
  Karpenter `EC2NodeClass`/`NodePool` are cluster-scoped (no namespace at all).
- `base/kustomization.yaml` — aggregates both.

The prod overlay scopes the generated `app-config` ConfigMap to
`sales-pipeline` explicitly (on the generator), rather than via a blanket
directive that would clobber the platform namespaces.

## Layout

```
k8s/
├── base/
│   ├── kustomization.yaml           # aggregates app/ + platform/
│   ├── app/                         # app workloads (namespace: sales-pipeline)
│   │   ├── kustomization.yaml
│   │   ├── 00-namespace.yaml
│   │   ├── 01-serviceaccounts.yaml  # api + worker SAs (IRSA placeholders)
│   │   ├── 03-api-deployment.yaml   # Deployment + Service + HPA (CPU)
│   │   ├── 04-worker-deployment.yaml
│   │   ├── 05-worker-scaledobject.yaml  # KEDA queue-depth, scale-to-zero
│   │   ├── 07-instrumentation.yaml  # OTel auto-instrumentation
│   │   ├── 10-pdb.yaml              # PodDisruptionBudgets
│   │   └── 11-networkpolicy.yaml    # default-deny + scoped egress
│   └── platform/                    # platform glue (own namespaces)
│       ├── kustomization.yaml
│       ├── 08-podmonitor.yaml       # Prometheus scrape configs
│       ├── 09-karpenter-nodepools.yaml
│       ├── 12-otel-collector.yaml   # OpenTelemetryCollector CR
│       └── 13-prometheus-rules.yaml # alerting rules
├── overlays/prod/
│   └── kustomization.yaml           # ALL value injection lives here
└── argocd/
    └── application.yaml             # the ArgoCD Application (applied at bootstrap)
```

## Where values get injected (all in overlays/prod/kustomization.yaml)

- **images** — ECR repo URLs + tag. CI bumps the tag:
  `kustomize edit set image REPLACE_ECR_API_REPO=<repo>:<sha>`
- **configMapGenerator** — `app-config` (region, SQS URL, bucket, DB
  host/port/name, `DB_IAM_AUTH`), consumed by both deployments via `envFrom`;
  `infra-values` (cluster name, Karpenter node role), a local-config generator
  that feeds replacements only and never becomes a ConfigMap in the cluster.
- **patches** — per-ServiceAccount IRSA role ARN (api and worker get DIFFERENT
  roles — the least-privilege split).
- **replacements** — `app-config` region + queue URL into the KEDA ScaledObject;
  `infra-values` node role + cluster name into the EC2NodeClass `spec.role` and
  both `karpenter.sh/discovery` tags.

`scripts/bootstrap-overlay.sh` maps nine of these from Terraform outputs and
`REPLACE_GIT_REPO_URL` from its `<git_repo_url>` argument. The image
placeholders come from app.yml, not from Terraform.

## Testing the API (private backend — no Ingress)

The cluster is a private backend with no ALB/Ingress, and the EKS endpoint itself
is fully private — so first open the SSM port-forward tunnel to the control plane
(see RUNBOOK "Accessing the private cluster"), then:

```bash
# tunnel localhost:8000 to the API Service (ClusterIP)
kubectl -n sales-pipeline port-forward svc/api 8000:8000

# in another shell, hit it as if local:
curl -X POST localhost:8000/jobs -H 'content-type: application/json' \
  -d '{"records":[{"region":"West","amount":100,"sale_date":"2026-01-01","order_id":"a1"}]}'
curl localhost:8000/jobs/<job_id>
curl localhost:8000/jobs/<job_id>/result
```

Access is gated by your AWS IAM + EKS RBAC (your `kubectl` credentials) — a
stronger gate than a public login, and nothing is exposed to the internet.

## Observability (Prometheus / Grafana)

The monitoring stack (Prometheus + Grafana + Alertmanager) installs via the
`kube-prometheus-stack` Helm chart in the Terraform `platform/` module — it's
cluster infrastructure, not app manifests.

Scrape discovery uses **PodMonitor** CRDs (08-podmonitor.yaml), the
kube-prometheus-stack-native mechanism:
- **api** PodMonitor → scrapes the `http` port (8000) `/metrics` (FastAPI
  instrumentator: request rate, latency, status codes).
- **worker** PodMonitor → scrapes the `metrics` port (9100) `/metrics`
  (custom metrics: processing-time histogram, records processed/rejected,
  rejection reasons, jobs by outcome).

Access Grafana (no public ingress by design):
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# then http://localhost:3000  (admin / the sales-pipeline/grafana-admin secret)
```

CloudWatch still covers the managed AWS layer (RDS, SQS, EKS). Prometheus
adds the application tier plus nodes, kubelet, CoreDNS, apiserver and
kube-state-metrics; the scheduler, controller-manager, etcd and kube-proxy
scrapes are disabled in the platform module because EKS does not expose them.

## Apply

```bash
# ArgoCD syncs overlays/prod automatically (GitOps). To inspect what it renders:
kustomize build overlays/prod | less
```

(Applied after Terraform is up — see RUNBOOK Phase 2 for the preflight. The
Application sets `CreateNamespace=false`, so the Helm-created `monitoring` and
`opentelemetry` namespaces must already exist and nothing checks that. Inside
the sync, the Namespace and the Instrumentation carry `sync-wave: "-1"`, so they
apply before the app pods.)

## Compute split: On-Demand API, Spot worker (Karpenter NodePools)

`09-karpenter-nodepools.yaml` defines an EC2NodeClass and two NodePools:
- **on-demand** — stable capacity. The API pins here via `nodeSelector:
  capacity: on-demand`.
- **spot** — interruptible, cheaper. Tainted (`capacity-spot=true:NoSchedule`)
  so only workloads that tolerate it land there. The worker pins here via
  `nodeSelector: capacity: spot` + the matching toleration.

The worker is safe on Spot because SQS redelivers on interruption and the worker
is idempotent — a node reclaim mid-job just means the message reappears and is
reprocessed safely. The API stays On-Demand for predictable request-serving.

Discovery: NodeClass selects subnets/SGs by the `karpenter.sh/discovery:
<cluster>` tag, set in Terraform on both the private subnets and the node SG.

**AMI policy.** `amiSelectorTerms: alias: al2023@latest`, deliberately
unpinned. The NodePool budgets bound the resulting drift: 10% of nodes at a
time, and `Drifted` replacement only between 03:00 and 04:00 UTC.

## Workload hardening (scheduling + security posture)

- **PodDisruptionBudgets** (`10-pdb.yaml`) — see "API availability" above.
- **securityContext** (both deployments): pod-level `runAsNonRoot` and
  `seccompProfile: RuntimeDefault`; container-level `readOnlyRootFilesystem`,
  `allowPrivilegeEscalation: false`, drop ALL caps. The namespace enforces Pod
  Security Admission `restricted` (`00-namespace.yaml` labels), which covers all
  of those EXCEPT `readOnlyRootFilesystem` — not a PSA control, so nothing
  enforces that one. No writable `/tmp` is needed: neither app writes to the
  filesystem and the OTel init container writes only into its own emptyDir.
- **topologySpreadConstraints** (API): `maxSkew: 1` over zone, so the three
  replicas spread across the two AZs instead of stacking in one.
  `ScheduleAnyway` so it's a preference, not a hard block when capacity is tight.
- **NetworkPolicy** (`11-networkpolicy.yaml`): default-deny ingress AND egress.
  Allows are monitoring→api:8000 and worker:9100, kube-dns, and app egress on
  443/5432/4318 except 169.254.169.254. The VPC CNI enforces them —
  `enableNetworkPolicy` is set on the addon.
- **Liveness/readiness split** is already correct in the app: `/healthz`
  (liveness) is dependency-free (`{"status":"ok"}`); `/readyz` does the DB/SQS/S3
  checks. So a DB blip fails readiness (pod pulled from rotation) but NOT liveness
  (no restart storm). The worker also already handles SIGTERM (stops pulling
  after the in-flight message), so the 60s grace period is real, not decorative.
- **Resource limits** are request=limit. Memory is sized from
  `loadtest/plateau_test.py` (see DESIGN.md, "The limits are measured, not
  guessed"): API 1Gi over a 446 MiB peak with 200,000 records in flight in
  one container, worker 512Mi over a 106 MiB peak. Both peaks were measured
  under docker compose, without the OTel auto-instrumentation injected here,
  so the headroom has to cover that too. CPU (API 1, worker 500m) was set by
  judgment. Nothing in the pod caps in-flight records, so a pod holding more
  than 200,000 at once is outside what was measured. Re-run the test before
  changing either limit.
