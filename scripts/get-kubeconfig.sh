#!/usr/bin/env sh
# =============================================================================
# scripts/get-kubeconfig.sh
#
# THE single cloud-specific auth shim for idea-board.
#
# Everything else in this repo (Terraform module interfaces, the Helm chart, the
# portable platform layer, the AI tooling) is cloud-agnostic. Talking to a managed
# Kubernetes control plane is the one place a cloud CLI is unavoidable, so it is
# quarantined *here* and nowhere else.
#
# Usage:
#     ./scripts/get-kubeconfig.sh <aws|gcp>
#
# It reads the cluster name and region from the already-applied Terraform stack
# (infra/stacks/<cloud>) and points the local kubeconfig at that cluster:
#
#     aws) aws eks    update-kubeconfig      --name <cluster> --region <region>
#     gcp) gcloud container clusters get-credentials <cluster> --region <region>
#
# Contract expectation (both stacks): `terraform output -raw cluster_name` and
# `terraform output -raw region` are defined and identical in meaning. The AWS
# stack exposes both today; the GCP stack must expose the same two outputs.
#
# Environment overrides (all optional):
#   STACK_DIR   Terraform stack directory (default: infra/stacks/<cloud>)
#   TERRAFORM   Terraform binary          (default: terraform)
#   GCP_PROJECT If set, passed to gcloud as --project (GCP only)
#
# POSIX sh only (no bashisms) so it runs unchanged in CI and on any dev machine.
# =============================================================================

set -eu

CLOUD="${1:-}"
if [ -z "$CLOUD" ]; then
	echo "usage: $0 <aws|gcp>" >&2
	exit 2
fi

TERRAFORM="${TERRAFORM:-terraform}"
STACK_DIR="${STACK_DIR:-infra/stacks/$CLOUD}"

if [ ! -d "$STACK_DIR" ]; then
	echo "error: stack directory '$STACK_DIR' not found (has the stack been applied?)" >&2
	exit 1
fi

# Pull the two contract outputs the shim needs. -raw yields the bare string.
CLUSTER="$("$TERRAFORM" -chdir="$STACK_DIR" output -raw cluster_name)"
REGION="$("$TERRAFORM" -chdir="$STACK_DIR" output -raw region)"

if [ -z "$CLUSTER" ] || [ -z "$REGION" ]; then
	echo "error: could not read cluster_name/region from '$STACK_DIR' terraform outputs" >&2
	exit 1
fi

echo "Configuring kubeconfig for cloud=$CLOUD cluster=$CLUSTER region=$REGION"

case "$CLOUD" in
aws)
	aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
	;;
gcp)
	# Regional GKE cluster (contract uses region, not zone). The gke-gcloud-auth-plugin
	# must be installed for kubectl/helm to authenticate (CI installs it).
	if [ -n "${GCP_PROJECT:-}" ]; then
		gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$GCP_PROJECT"
	else
		gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"
	fi
	;;
*)
	echo "error: unsupported cloud '$CLOUD' (expected 'aws' or 'gcp')" >&2
	exit 2
	;;
esac

echo "kubeconfig updated; current context: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
