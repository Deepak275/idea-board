# ai/envgen

Turn a plain-English **intent** into a **proposed, guardrailed, cloud-agnostic
sizing config** for `idea-board`. It renders a Terraform `.tfvars` snippet and a
Helm `values` snippet for a human to review — it **never applies anything**.

## What it does

1. Asks Claude (`claude-opus-5`, chosen for stronger reasoning) to **propose** a
   config from a deliberately **constrained** vocabulary:
   `{node_size, node_count, backend_replicas, frontend_replicas, hpa_min, hpa_max}`
   where `node_size ∈ {small, medium, large}` (the cloud-agnostic t-shirt sizes).
2. **Validates** the proposal against [`envgen.schema.json`](./envgen.schema.json)
   (`jsonschema`) **and** hard cross-field guardrails (ranges + `hpa_min ≤
   backend_replicas ≤ hpa_max`, `hpa_max ≥ hpa_min`).
3. **Renders** the validated proposal as tfvars + Helm values snippets and prints
   them for human approval.

## The guardrail (propose → validate → approve → deterministic action)

The model **only proposes**. Three independent layers protect the pipeline:

- the response is constrained to the JSON Schema via structured outputs;
- `jsonschema` re-validates the parsed object (authoritative);
- hard-coded guardrails reject impossible/unsafe combinations.

Only after all three pass are snippets rendered — and **nothing is applied**. A
human reviews and applies. Because the vocabulary is the t-shirt size set, the
same proposal maps identically onto AWS (EKS/RDS) and GCP (GKE/Cloud SQL).

**The LLM never receives cloud credentials** — its only input is the intent string.

## Install

```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
```

## Usage

```bash
# Positional intent:
python ai/envgen/main.py "cost-sensitive staging"

# Or via flag, and also print the raw validated JSON:
python ai/envgen/main.py --intent "high-availability production" --json

# Only the Helm snippet:
python ai/envgen/main.py "demo for one reviewer" --format helm
```

### Example output (illustrative)

```
# ai/envgen proposal for intent: 'cost-sensitive staging'
# node_size=small node_count=1 backend_replicas=1 frontend_replicas=1 hpa=[1,3]
# >>> REVIEW and apply manually. This tool never applies changes. <<<

# ---- terraform.tfvars (cluster sizing) -------------------------------
node_size  = "small"
node_count = 1

# ---- values-<cloud> overlay (Helm) -----------------------------------
backend:
  replicas: 1
frontend:
  replicas: 1
hpa:
  enabled: true
  min: 1
  max: 3
```

## Exit codes

`0` on a validated, guardrail-passing proposal; `2` on missing intent, missing
`ANTHROPIC_API_KEY`, API failure, or a proposal that fails schema/guardrail
validation (rejected — never silently applied).
