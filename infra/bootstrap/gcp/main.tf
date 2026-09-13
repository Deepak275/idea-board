# infra/bootstrap/gcp/main.tf
#
# The GCP identity seed for keyless CI: Workload Identity Federation for GitHub
# Actions + a deploy service account + the External-Secrets SA. Mirrors what
# scripts/bootstrap-aws-oidc.sh does for AWS, but as reviewable, plan-first IaC.

# --- Enable the APIs the stacks/add-ons need (idempotent) -------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# --- Workload Identity Federation: GitHub Actions -> GCP (keyless) ----------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "idea-board-github"
  display_name              = "idea-board GitHub"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions OIDC"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # Restrict federation to THIS repo. We condition on `assertion.repository`
  # (the stable "owner/repo" string) rather than `sub` — GitHub's sub can carry
  # immutable numeric IDs (the exact trap that bit the AWS role), so matching on
  # repository is both correct and immune to that.
  attribute_condition = "assertion.repository == \"${var.github_repo}\""
}

# --- Deploy service account (CI impersonates this via WIF) ------------------
resource "google_service_account" "deploy" {
  account_id   = "idea-board-gha-deploy"
  display_name = "idea-board GitHub Actions deploy"
}

# DEMO breadth (mirrors the AWS AdministratorAccess demo role). For production,
# scope these down. servicenetworking is needed for private Cloud SQL (PSA).
resource "google_project_iam_member" "deploy" {
  for_each = toset([
    "roles/container.admin",
    "roles/cloudsql.admin",
    "roles/compute.networkAdmin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountUser",
    "roles/iam.serviceAccountAdmin", # lets the pipeline set the ESO Workload-Identity binding post-cluster
    "roles/storage.admin",
    "roles/servicenetworking.networksAdmin",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

# Let the GitHub repo impersonate the deploy SA (the keyless handshake).
resource "google_service_account_iam_member" "deploy_wif" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# --- External Secrets Operator SA (pods -> Secret Manager via GKE WI) -------
resource "google_service_account" "eso" {
  account_id   = "idea-board-eso"
  display_name = "idea-board External Secrets Operator"
}

resource "google_project_iam_member" "eso_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.eso.email}"
}

# NOTE: the ESO Workload-Identity binding (KSA external-secrets/external-secrets
# -> this GSA) is NOT here — it needs the <project>.svc.id.goog pool, which GKE
# only auto-creates once a Workload-Identity cluster exists. It's created in the
# GCP stack (infra/stacks/gcp) with depends_on the cluster.
