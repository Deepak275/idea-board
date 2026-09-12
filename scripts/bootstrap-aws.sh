#!/usr/bin/env bash
# Bootstrap the AWS Terraform remote-state backend (run ONCE per account/region).
# Creates: an encrypted, versioned, private S3 bucket for state + a DynamoDB
# lock table. These must exist BEFORE `terraform init` on the s3 backend
# (chicken-and-egg: Terraform can't create its own backend store).
#
# Usage:  bash scripts/bootstrap-aws.sh <region>      e.g. us-east-1
set -euo pipefail

REGION="${1:?usage: bootstrap-aws.sh <region>   (e.g. us-east-1)}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="idea-board-tfstate-${ACCOUNT}-${REGION}"
TABLE="idea-board-tf-locks"

echo ">> account=${ACCOUNT} region=${REGION}"
echo ">> state bucket = ${BUCKET}"
echo ">> lock table   = ${TABLE}"

# --- S3 state bucket (idempotent) ---
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "   bucket already exists — ok"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "   bucket created"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# --- DynamoDB lock table (idempotent) ---
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "   lock table already exists — ok"
else
  aws dynamodb create-table --table-name "$TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "   lock table created"
fi

cat <<EOF

============================================================
Backend ready. Use these for 'terraform init':
  bucket         = ${BUCKET}
  dynamodb_table = ${TABLE}
  region         = ${REGION}
============================================================
EOF
