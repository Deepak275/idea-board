# infra/stacks/aws/backend.tf
#
# Remote state on S3 with a DynamoDB lock table. This is a PARTIAL backend
# configuration on purpose — bucket / key / region / lock-table names are NOT
# hardcoded here so the same code works across accounts and environments.
#
# Supply the rest at init time, e.g.:
#
#   terraform -chdir=infra/stacks/aws init \
#     -backend-config="bucket=my-tfstate-bucket" \
#     -backend-config="key=idea-board/aws/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=my-tf-locks" \
#     -backend-config="encrypt=true"
#
# ...or point at a *.hcl file:  terraform init -backend-config=backend.hcl
#
# For a quick local run with no remote state, init with -backend=false.

terraform {
  backend "s3" {}
}
