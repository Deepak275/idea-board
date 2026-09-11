#!/usr/bin/env bash
# =============================================================================
# Cloud-agnostic contract test.
#
# The whole "add a 3rd cloud by writing one adapter" promise depends on every
# cloud's modules exposing the IDENTICAL interface. This test enforces that:
#
#   * each module (network|cluster|database) declares the SAME set of input
#     variable names across AWS and GCP, and
#   * the SAME set of output names, and
#   * the two stacks expose the same outputs (GCP is allowed the one extra
#     `project_id`, which AWS has no equivalent for).
#
# Pure text comparison — no terraform/cloud needed. Exit non-zero on drift.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)" # -> infra/
fail=0

names() { # extract sorted `variable "x"` or `output "x"` names from a file
  local kind="$1" file="$2"
  [ -f "$file" ] && grep -oE "^${kind} \"[^\"]+\"" "$file" | sed -E "s/^${kind} \"([^\"]+)\"/\1/" | sort || true
}

check() { # compare a kind (variable|output) for one module across clouds
  local module="$1" kind="$2"
  local aws gcp
  aws="$(names "$kind" "$ROOT/modules/aws/$module/${kind}s.tf")"
  gcp="$(names "$kind" "$ROOT/modules/gcp/$module/${kind}s.tf")"
  if [ "$aws" = "$gcp" ]; then
    echo "  OK   $module ${kind}s: $(echo "$aws" | tr '\n' ' ')"
  else
    echo "  FAIL $module ${kind}s differ between AWS and GCP:"
    diff <(echo "$aws") <(echo "$gcp") | sed 's/^/       /' || true
    fail=1
  fi
}

echo "== module interface parity (AWS vs GCP) =="
for m in network cluster database; do
  check "$m" variable
  check "$m" output
done

echo "== stack output parity (GCP may add only 'project_id') =="
aws_out="$(names output "$ROOT/stacks/aws/outputs.tf")"
gcp_out="$(names output "$ROOT/stacks/gcp/outputs.tf" | grep -v '^project_id$' || true)"
if [ "$aws_out" = "$gcp_out" ]; then
  echo "  OK   stack outputs match (ignoring GCP-only project_id)"
else
  echo "  FAIL stack outputs differ:"
  diff <(echo "$aws_out") <(echo "$gcp_out") | sed 's/^/       /' || true
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "CONTRACT DRIFT DETECTED — the clouds no longer share one interface." >&2
  exit 1
fi
echo "cloud-agnostic contract: intact ✅"
