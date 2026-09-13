# infra/bootstrap/gcp/outputs.tf
#
# `terraform output repo_variables` prints exactly the GitHub repo variables to
# set (paste them back and they get wired into provision.yml / deploy.yml).

output "gcp_workload_identity_provider" {
  description = "Full WIF provider resource name for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "gcp_deploy_service_account" {
  value = google_service_account.deploy.email
}

output "gcp_eso_sa_email" {
  value = google_service_account.eso.email
}

output "repo_variables" {
  description = "Set these as GitHub repo Variables (GCS_STATE_BUCKET is the bucket you created)."
  value = {
    GCP_PROJECT                    = var.project_id
    GCP_REGION                     = var.region
    GCP_WORKLOAD_IDENTITY_PROVIDER = google_iam_workload_identity_pool_provider.github.name
    GCP_DEPLOY_SERVICE_ACCOUNT     = google_service_account.deploy.email
    GCP_ESO_SA_EMAIL               = google_service_account.eso.email
  }
}
