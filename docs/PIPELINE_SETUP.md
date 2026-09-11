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
`GCP_PROJECT`, `GCP_REGION`, `GCP_ESO_SA_EMAIL` (Workload Identity Federation —
GCP's OIDC equivalent).

## 3. Deploy

**Actions → Deploy → Run workflow** → pick `cloud: aws` (or `deploy_both: true`).
The pipeline runs: **verify (lint+tests+scans)** → build+push to GHCR →
`terraform apply` infra → get-kubeconfig → `terraform apply` platform
(ingress-nginx, cert-manager, ESO) → `helm upgrade` → **AI health-check +
post-deploy link check** → keep or roll back. The app URL appears in the run
summary.

## 4. Security scanning (report mode)

The `security` job (Trivy: deps, secrets, IaC/Dockerfile/K8s misconfig) and the
post-build image scan currently run in **report mode** (visible in the run
summary, non-blocking) — except the **secret scan, which blocks**. Flip the
vuln/misconfig scans to blocking (`exit-code: 1`) once you've triaged the first
run's findings. This was left report-mode because the thresholds could not be
pre-validated locally (Trivy was unavailable in the dev sandbox).
