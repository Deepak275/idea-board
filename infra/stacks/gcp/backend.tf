# infra/stacks/gcp/backend.tf
#
# Remote state on Google Cloud Storage (GCS). PARTIAL backend configuration on
# purpose — bucket / prefix are NOT hardcoded so the same code works across
# projects and environments (mirrors the AWS S3 backend approach).
#
# Supply the rest at init time, e.g.:
#
#   terraform -chdir=infra/stacks/gcp init \
#     -backend-config="bucket=my-tfstate-bucket" \
#     -backend-config="prefix=idea-board/gcp"
#
# ...or point at a *.hcl file:  terraform init -backend-config=backend.hcl
# For a quick local run with no remote state, init with -backend=false.

terraform {
  backend "gcs" {}
}
