# Architecture

This document goes one level deeper than the [README](../README.md): it explains the
request lifecycle, the data flow, the deployment pipeline, and *why* each boundary exists.
If you only want to run or deploy the app, the README is enough.

## Design principles

1. **Two planes, cleanly separated.** A *portable plane* (application, Helm chart,
   Kubernetes add-ons, AI tooling) that is byte-for-byte identical on every cloud, and a
   thin *cloud-specific plane* (one Terraform stack per cloud + one auth shim script) that
   is the only place provider APIs are allowed to appear.
2. **12-factor application.** The app reads *all* configuration from the environment and
   has **zero cloud awareness**. It cannot tell whether it's running under Docker Compose,
   EKS, or GKE — it only knows `DATABASE_URL`.
3. **Contract-first infrastructure.** Every cloud implements the same Terraform module
   interface. Swapping clouds swaps *implementations*, not *shapes*.
4. **AI advises, humans and deterministic tools decide.** Every AI output is validated
   against a JSON Schema; anything that mutates infrastructure passes through a human gate.
5. **No static cloud credentials, ever.** CI authenticates via OIDC federation; the DB
   password lives in a cloud secret store and reaches pods only through External Secrets
   Operator.

## Components

### Backend — `app/backend`

- **Stack:** FastAPI on Python 3.12, SQLAlchemy 2.x with the psycopg (v3) driver,
  listening on `:8000`.
- **Endpoints:**
  - `GET /api/ideas` → JSON array of ideas.
  - `POST /api/ideas` with body `{"content": "..."}` → `201 Created` with the created idea.
  - `GET /healthz` → liveness; does **not** touch the DB (so a DB blip doesn't kill the pod).
  - `GET /readyz` → readiness; checks the DB (so traffic isn't routed before the DB is reachable).
- **Config:** strictly from env. `DATABASE_URL` in the form
  `postgresql+psycopg://USER:PASS@HOST:PORT/DBNAME`. CORS allows the frontend origin.
- **Schema:** an Alembic migration creates
  `ideas(id BIGSERIAL PRIMARY KEY, content TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())`.

The split between `/healthz` and `/readyz` is deliberate: Kubernetes uses the liveness
probe to decide whether to *restart* a pod and the readiness probe to decide whether to
*send it traffic*. Tying liveness to the DB would cause a cascading restart storm during a
transient DB outage — exactly when you least want it.

### Frontend — `app/frontend`

- **Stack:** React + Vite + TypeScript. Lists ideas and offers a submit form that POSTs
  then refreshes the list.
- **Config:** reads the API base URL from `VITE_API_BASE_URL` (default
  `http://localhost:8000`). In production it is built to static assets and served by
  **nginx on :80**.

### Database — managed Postgres

Postgres `:5432`. Locally it's the `db` Compose service; in the cloud it's AWS RDS or GCP
Cloud SQL, provisioned by the Terraform `database` module. The app is identical either
way — only `DATABASE_URL` differs.

### Packaging — Docker + GHCR

Two images, referenced everywhere by the same names with CI-substituted `OWNER`/`TAG`:

- `ghcr.io/OWNER/idea-board-backend:TAG`
- `ghcr.io/OWNER/idea-board-frontend:TAG`

### Deploy unit — Helm chart `charts/idea-board`

- Release name `idea-board`, namespace `idea-board`.
- Templates: `deployment-backend`, `deployment-frontend`, `service-backend`,
  `service-frontend`, `ingress`, `hpa-backend`, `externalsecret-db`, `migration-job`,
  `_helpers.tpl`.
- Values keys of note: `backend.image.{repository,tag}`, `backend.replicas`,
  `frontend.image.{repository,tag}`, `frontend.replicas`, `ingress.host`,
  `ingress.className=nginx`, `resources`, `hpa.{enabled,min,max}`.
- The backend gets `DATABASE_URL` from a Kubernetes Secret `idea-board-db` (key
  `DATABASE_URL`), materialized by the ExternalSecret (below).
- **Migrations run as a Helm `pre-install`/`pre-upgrade` Job** using the backend image and
  `alembic upgrade head`. Running migrations as a hook (rather than an init container on
  every replica) guarantees exactly one migration run per release, before the new pods
  come up.

Per-cloud overlays `values-aws.yaml` / `values-gcp.yaml` change only `storageClass` and
load-balancer annotations.

### Cluster add-ons — `infra/platform`

A portable Terraform config (or documented helmfile) that, given a kubeconfig, installs
via `helm_release`: **ingress-nginx**, **cert-manager**, **External Secrets Operator**, the
**ClusterSecretStore `cloud-secrets`**, and the **idea-board chart** with
`-f values.yaml -f values-<cloud>.yaml`. This layer is identical on both clouds except the
ClusterSecretStore provider/auth block (chosen by a variable).

## Request lifecycle (in the cluster)

```
Client ──HTTPS──► ingress-nginx ──┬──► frontend Service :80 ──► frontend pod (nginx, static React)
   (TLS terminated here,          │
    cert from cert-manager)       └──► backend Service :8000 ─► backend pod (FastAPI)
                                                                     │
                                                                     ▼
                                                    DATABASE_URL (from Secret idea-board-db)
                                                                     │
                                                                     ▼
                                                     managed Postgres (RDS / Cloud SQL) :5432
```

1. The browser loads the frontend over HTTPS. Ingress-nginx terminates TLS using a
   certificate cert-manager obtained from Let's Encrypt (annotation-driven).
2. The React app calls the backend at `VITE_API_BASE_URL`.
3. The backend reads/writes the `ideas` table using the SQLAlchemy engine built from
   `DATABASE_URL`.
4. Kubernetes probes `/healthz` (restart decisions) and `/readyz` (traffic decisions)
   independently.

## Secret flow (End to end)

```
Terraform database module ──writes password──► cloud secret store (Secrets Manager / Secret Manager)
                                                       key: idea-board/db
                                                            │
External Secrets Operator (ClusterSecretStore "cloud-secrets")
   reads remote key idea-board/db ─────────────────────────┘
                                                            │
ExternalSecret "idea-board-db"  ──materializes──► K8s Secret "idea-board-db" (key DATABASE_URL)
                                                            │
                            backend Deployment + migration Job read DATABASE_URL ◄┘
```

The password is never committed to Git, never rendered into Helm values, and never printed
into logs. The only components that see it are the cloud secret store, ESO, and the pods
that actually connect to the database.

## CI/CD pipeline

Two workflows under `.github/workflows`:

- **`ci.yml` (on PR):** lints, runs backend tests, `terraform fmt`/`validate`, and
  `helm lint`. Fast feedback, no cloud access.
- **`deploy.yml` (workflow_dispatch, inputs `cloud` + `environment`, matrix-capable):**
  1. Build & push both images to GHCR.
  2. `terraform -chdir=infra/stacks/$CLOUD init && apply` (network → cluster → database).
  3. `scripts/get-kubeconfig.sh $CLOUD` — reads cluster/region from Terraform output.
  4. `terraform apply` in `infra/platform` (add-ons).
  5. `helm upgrade --install idea-board charts/idea-board -f values.yaml -f values-$CLOUD.yaml`.
  6. Run `ai/healthcheck`; **exit 1 (unhealthy) → `helm rollback` + post summary.**

Cloud auth is via **OIDC** (no static keys). `ANTHROPIC_API_KEY` is provided as a repo
secret and is used only by the AI steps.

## AI subsystem

Three Claude-backed helpers, all following **propose → validate → human-approve →
deterministic execute**:

| Tool | Path | Model | Role in the system |
|------|------|-------|--------------------|
| health-check | `ai/healthcheck` | `claude-sonnet-5` | Reads `kubectl` rollout/events/logs, returns `{healthy, confidence, reasons, summary}`, gates rollback via exit code. |
| env-gen | `ai/envgen` | `claude-opus-5` | Turns an intent string into a constrained `{node_size, node_count, backend_replicas, frontend_replicas, hpa_min, hpa_max}`; renders tfvars + values for human approval. |
| explain | `ai/explain` | `claude-sonnet-5` | Summarizes a `terraform plan` / `helm diff`, flagging destructive/replacement changes; posts as a PR comment. |

Every response is validated with `jsonschema` against a checked-in schema; env-gen also
clamps to hard min/max guardrails. The LLM never receives cloud credentials and never
executes raw text.

## Why these boundaries

- **App has no cloud awareness** → it's trivially testable locally and portable by default.
- **Module contract, not module copy-paste** → adding a cloud is additive (see
  [`ADDING_A_CLOUD.md`](ADDING_A_CLOUD.md)), and stacks stay near-identical.
- **ESO instead of baked-in secrets** → rotation and least-privilege live in the cloud's
  own secret store, not in Git.
- **AI behind schema + human gates** → we get AI leverage without ceding control of
  destructive actions.

See [`ADDING_A_CLOUD.md`](ADDING_A_CLOUD.md) for the concrete steps to extend this to a
third provider, and the [README](../README.md) for the honest list of where the
abstraction leaks.
