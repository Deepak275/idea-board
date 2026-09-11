# ai/healthcheck

AI-assisted **post-deploy health verdict** for the `idea-board` app, used by CI to
decide whether to keep a release or roll it back.

## What it does

1. Collects **read-only** cluster diagnostics via `kubectl` subprocesses:
   rollout status, deployment/pod listings (incl. `RESTARTS`), recent events, and
   recent backend/frontend pod logs.
2. Sends that text to Claude (`claude-sonnet-5`) and asks for a **structured**
   verdict: `{healthy, confidence, reasons, summary}`.
3. **Validates** the model's JSON against [`healthcheck.schema.json`](./healthcheck.schema.json)
   with `jsonschema`.
4. Prints a human-readable summary and sets the process exit code so CI can gate.

## The guardrail (propose → validate → approve → deterministic action)

The LLM is **advisory only**. It *proposes* a verdict; we never execute raw model
text. The proposal is *validated* against a strict JSON Schema, and the only thing
that happens as a result is a deterministic branch on the `healthy` boolean / exit
code inside the reviewed CI pipeline (the "approved tool"). Malformed or
unvalidatable output **fails closed** (exit 2), never a guessed verdict.

**The LLM never receives cloud credentials.** Only the text output of `kubectl`
is sent. The kubeconfig, cloud tokens, and Kubernetes Secrets are never read or
forwarded, and pod logs are scrubbed for connection strings / password-like
tokens before they leave the process (see `redact()` in `main.py`).

## Exit codes

| Code | Meaning | CI action |
|------|---------|-----------|
| `0`  | Healthy (validated model verdict) | keep the release |
| `1`  | Unhealthy (validated model verdict) | `helm rollback` |
| `2`  | Inconclusive / tool error (API failure, malformed or schema-invalid output, kubectl unavailable) | treat as "not verified" per policy |

## Install

```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
```

## Usage

```bash
# Default namespace / deployment names (idea-board, idea-board-backend/frontend):
python -m ai.healthcheck.main            # or: python ai/healthcheck/main.py

# Custom namespace + more log lines, print the raw JSON verdict too:
python ai/healthcheck/main.py -n idea-board --log-lines 200 --json

# See EXACTLY what (redacted) text would be sent to Claude — makes no API call:
python ai/healthcheck/main.py --print-context

# Point at a specific kube context / model:
python ai/healthcheck/main.py --context prod-eks --model claude-sonnet-5
```

### In CI (see `.github/workflows/deploy.yml`)

```bash
if ! python ai/healthcheck/main.py -n idea-board; then
  helm rollback idea-board -n idea-board
fi
```

## Options

Run `python ai/healthcheck/main.py --help`. Key flags: `-n/--namespace`,
`--backend-deployment`, `--frontend-deployment`, `--context`, `--kubectl`,
`--log-lines`, `--timeout`, `--rollout-timeout`, `--model`, `--max-tokens`,
`--json`, `--print-context`.
