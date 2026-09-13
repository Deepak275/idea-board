#!/usr/bin/env bash
# =============================================================================
# One-time bootstrap so the GitHub Actions pipeline (deploy.yml) can deploy to
# AWS *keylessly* via OIDC — no long-lived access keys stored in GitHub.
#
# Creates:
#   1. the GitHub OIDC identity provider in your AWS account (if absent)
#   2. an IAM deploy role the repo can assume  (-> AWS_DEPLOY_ROLE_ARN)
#   3. (optional, after the cluster exists) an IRSA role for External-Secrets
#      so the pipeline's ESO path can read the DB secret from Secrets Manager
#      (-> AWS_ESO_ROLE_ARN)
#
# Run with your AWS ADMIN creds:  bash scripts/bootstrap-aws-oidc.sh <owner/repo> [region]
#   e.g. bash scripts/bootstrap-aws-oidc.sh Deepak275/idea-board us-east-1
# Then set the printed values as GitHub repo Variables (see docs/PIPELINE_SETUP.md).
# =============================================================================
set -euo pipefail

REPO="${1:?usage: bootstrap-aws-oidc.sh <github_owner/repo> [region]}"
REGION="${2:-us-east-1}"
OWNER="${REPO%%/*}"     # for the immutable-ID subject form repo:<owner>@<id>/<repo>@<id>:*
REPONAME="${REPO##*/}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
OIDC_HOST="token.actions.githubusercontent.com"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/${OIDC_HOST}"
DEPLOY_ROLE="idea-board-gha-deploy"
ESO_ROLE="idea-board-eso"

echo ">> account=${ACCOUNT} repo=${REPO} region=${REGION}"

# --- 1. GitHub OIDC provider (idempotent) ---------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "   OIDC provider exists"
else
  # Thumbprint is no longer verified by AWS for GitHub's provider, but the API
  # still requires one; this is GitHub's well-known intermediate CA thumbprint.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_HOST}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  echo "   created OIDC provider"
fi

# --- 2. Deploy role assumable by this repo --------------------------------
DEPLOY_TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Federated":"${OIDC_ARN}"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{
    "StringEquals":{"${OIDC_HOST}:aud":"sts.amazonaws.com"},
    "StringLike":{"${OIDC_HOST}:sub":["repo:${REPO}:*","repo:${OWNER}@*/${REPONAME}@*:*"]}
  }}]}
JSON
)
if aws iam get-role --role-name "$DEPLOY_ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$DEPLOY_ROLE" --policy-document "$DEPLOY_TRUST"
  echo "   updated ${DEPLOY_ROLE} trust"
else
  aws iam create-role --role-name "$DEPLOY_ROLE" --assume-role-policy-document "$DEPLOY_TRUST" >/dev/null
  echo "   created ${DEPLOY_ROLE}"
fi
# DEMO: AdministratorAccess. For production, scope to EC2/EKS/RDS/IAM/SecretsMgr/ELB.
aws iam attach-role-policy --role-name "$DEPLOY_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
DEPLOY_ARN="arn:aws:iam::${ACCOUNT}:role/${DEPLOY_ROLE}"

# --- 3. ESO IRSA role (only if the cluster/OIDC already exists) ------------
# Requires the EKS cluster to have been created (its OIDC provider must exist).
# Reads it from the stack output if available.
ESO_ARN="(create after first cluster apply — see docs/PIPELINE_SETUP.md)"
if terraform -chdir=infra/stacks/aws output -raw oidc_provider >/dev/null 2>&1; then
  CLUSTER_OIDC_ARN="$(terraform -chdir=infra/stacks/aws output -raw oidc_provider)"
  CLUSTER_OIDC_HOST="${CLUSTER_OIDC_ARN#*oidc-provider/}"
  ESO_TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Federated":"${CLUSTER_OIDC_ARN}"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{
    "${CLUSTER_OIDC_HOST}:aud":"sts.amazonaws.com",
    "${CLUSTER_OIDC_HOST}:sub":"system:serviceaccount:external-secrets:external-secrets"
  }}}]}
JSON
)
  if aws iam get-role --role-name "$ESO_ROLE" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ESO_ROLE" --policy-document "$ESO_TRUST"
  else
    aws iam create-role --role-name "$ESO_ROLE" --assume-role-policy-document "$ESO_TRUST" >/dev/null
  fi
  # Least-privilege: read only the idea-board DB secret.
  aws iam put-role-policy --role-name "$ESO_ROLE" --policy-name read-idea-board-db \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],\"Resource\":\"arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:idea-board/db-*\"}]}"
  ESO_ARN="arn:aws:iam::${ACCOUNT}:role/${ESO_ROLE}"
  echo "   ESO IRSA role ready"
else
  echo "   (skipping ESO role — cluster OIDC not found yet; re-run after first tf apply)"
fi

cat <<EOF

============================================================
Set these as GitHub repo Variables (Settings -> Secrets and variables -> Actions -> Variables):
  AWS_DEPLOY_ROLE_ARN = ${DEPLOY_ARN}
  AWS_ESO_ROLE_ARN    = ${ESO_ARN}
  AWS_REGION          = ${REGION}
  TF_STATE_BUCKET     = idea-board-tfstate-${ACCOUNT}-${REGION}
  TF_LOCK_TABLE       = idea-board-tf-locks
  LETSENCRYPT_EMAIL   = you@example.com        # only needed if enabling TLS
And this as a repo Secret:
  ANTHROPIC_API_KEY   = <your key>             # for the AI health-check / explain
============================================================
EOF
