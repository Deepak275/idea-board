# Pipeline Setup — deploy via GitHub Actions (keyless OIDC)

This wires `deploy.yml` so the pipeline deploys to AWS/GCP with **no static keys**.
Once set up, you never run `helm`/`terraform` by hand — you trigger the workflow.

## 1. AWS (one-time)

Prereqs already done in this repo's earlier steps: the S3 state bucket + DynamoDB
lock table (`scripts/bootstrap-aws.sh`).

Run the OIDC bootstrap with your **admin** AWS creds:

```bash
bash scripts/bootstrap-aws-oidc.sh Deepak275/idea-board us-east-1
```

It creates the GitHub OIDC provider + the deploy role, and (if the cluster
already exists) the External-Secrets IRSA role. It prints the values below.

> **ESO IRSA note:** the ESO role's trust policy references the *EKS cluster's*
> OIDC provider, which only exists after the first `terraform apply`. So on a
> from-scratch deploy: run the pipeline once to create the cluster, then re-run
> `bootstrap-aws-oidc.sh` to create `AWS_ESO_ROLE_ARN`, set the variable, and
> re-run the pipeline. (Or, for a first URL, deploy with `externalSecret.enabled=false`
> and inject the DB secret directly — see the AWS deploy runbook.)

## 1b. GCP (one-time)

GCP's bootstrap is **Terraform**, not a shell script — `infra/bootstrap/gcp` (local state,
run once with your own gcloud creds) creates the keyless-CI plumbing symmetric to AWS:

```bash
# ADC for Terraform's google provider:
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
terraform -chdir=infra/bootstrap/gcp init
terraform -chdir=infra/bootstrap/gcp apply \
  -var="project_id=<your-gcp-project>" -var="github_repo=Deepak275/idea-board"
terraform -chdir=infra/bootstrap/gcp output repo_variables   # the GCP_* vars to paste into GitHub
```

It provisions the **Workload Identity Federation** pool + provider (trust scoped to this
repo — GCP's keyless-OIDC equivalent of the AWS OIDC provider), the **deploy** service
account (with the roles CI needs), the **ESO** service account
(`secretmanager.secretAccessor`), enables the required `google_project_service` APIs, and the
**GCS state bucket** (`GCS_STATE_BUCKET`, used by both the stack and — via a `gcs` backend
override `provision.yml` writes — the platform layer at `prefix=idea-board/gcp-platform`).

> **ESO Workload Identity note (mirrors the AWS IRSA note):** the binding that lets the ESO
> Kubernetes SA impersonate the ESO Google SA references the cluster's Workload Identity pool,
> which only exists **after** the GKE cluster is created. It therefore lives in the GCP
> *stack* (`depends_on` the cluster), not in this bootstrap — so a from-scratch GCP deploy
> completes in a single provision run.

## 2. GitHub repo Variables & Secrets

**Settings → Secrets and variables → Actions**

| Kind | Name | Value |
|---|---|---|
| Variable | `AWS_DEPLOY_ROLE_ARN` | from the bootstrap output |
| Variable | `AWS_ESO_ROLE_ARN` | from the bootstrap output (after cluster exists) |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `TF_STATE_BUCKET` | `idea-board-tfstate-<acct>-us-east-1` |
| Variable | `TF_LOCK_TABLE` | `idea-board-tf-locks` |
| Variable | `LETSENCRYPT_EMAIL` | your email (only if enabling TLS) |
| Variable | `INGRESS_HOST` | (optional) DNS name; omit to use the LB hostname |
| Variable | `AWS_PLAN_ROLE_ARN` | (optional) read-only role to enable the AI plan-explain PR job |
| Secret | `ANTHROPIC_API_KEY` | your Anthropic key (AI health-check / explain) |

For **GCP**, set `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT`,
`GCP_PROJECT`, `GCP_REGION`, `GCP_ESO_SA_EMAIL`, and **`GCS_STATE_BUCKET`** (the GCS bucket
for Terraform remote state — the GCP analogue of `TF_STATE_BUCKET`, used by both the stack
and the platform layer). All of these are printed by the §1b bootstrap's `repo_variables`
output. Workload Identity Federation is GCP's keyless-OIDC equivalent.

## 3. Provision, then deploy (two workflows)

Infra and app are **separate** pipelines so mutation is deliberate:

1. **Provision** (once per cluster, or on `infra/**` changes). **Actions → Provision
   infrastructure → Run workflow** → `cloud`, `action=apply` (a push only ever *plans*).
   Applies the stack (network → cluster → database), then the platform add-ons (ingress-nginx,
   cert-manager, ESO). Gated by the `production` GitHub Environment's approval rule; the
   optional `intent` box drives AI sizing (envgen).
2. **Deploy the app.** **Actions → Build & Deploy → Run workflow** → `cloud: aws` (or
   `deploy_both: true` to fan out to both clouds). Runs **verify (lint+tests+scans) → build +
   push to GHCR → read stack state + get-kubeconfig → `helm upgrade`** → **AI health-check
   (advisory) + deterministic keep/rollback gate** (helm rollout healthy **and** the public
   URL returns 200). The live URL appears in the run summary — it is intentionally **not**
   committed to the repo.

## 4. Security scanning (report mode)

The `security` job (Trivy: deps, secrets, IaC/Dockerfile/K8s misconfig) and the
post-build image scan currently run in **report mode** (visible in the run
summary, non-blocking) — except the **secret scan, which blocks**. Flip the
vuln/misconfig scans to blocking (`exit-code: 1`) once you've triaged the first
run's findings. This was left report-mode because the thresholds could not be
pre-validated locally (Trivy was unavailable in the dev sandbox).
