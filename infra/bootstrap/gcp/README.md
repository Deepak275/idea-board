# infra/bootstrap/gcp — GCP identity seed (run once, locally)

Creates the keyless-CI seed for GCP: a **Workload Identity Federation** pool +
GitHub provider, a **deploy** service account (+ roles), and the **External
Secrets** service account (+ Workload Identity binding). This is the one step
that can't run in CI (the pipeline needs the SA this creates in order to
authenticate — chicken-and-egg), so you run it once with your own `gcloud`
login. Everything after this is the normal, plan-first pipeline.

State is **local** on purpose (a tiny one-time seed). The GCS **state bucket for
the main stacks** is created out-of-band and is *not* managed here.

## Prerequisites
- `gcloud auth login` + `gcloud config set project <PROJECT_ID>` (done).
- The GCS state bucket already created (done).
- Terraform ≥ 1.5 installed locally. (No `application-default login` needed —
  the google provider uses your gcloud credentials.)

## Run (plan-first)
```bash
cd infra/bootstrap/gcp
terraform init
terraform plan  -var="project_id=<PROJECT_ID>" -var="region=us-central1"    # review
terraform apply -var="project_id=<PROJECT_ID>" -var="region=us-central1"
terraform output repo_variables    # paste these back
```

`terraform output repo_variables` prints the exact GitHub repo **Variables** to
set: `GCP_PROJECT`, `GCP_REGION`, `GCP_WORKLOAD_IDENTITY_PROVIDER`,
`GCP_DEPLOY_SERVICE_ACCOUNT`, `GCP_ESO_SA_EMAIL`. Also set `GCS_STATE_BUCKET` to
the bucket you created. Then trigger `provision.yml` (cloud=gcp, action=apply).
