# ai/explain

Plain-English explainer for `terraform plan` / `helm diff` output that **flags
destructive / replacement changes** so a human reviewer notices them. In CI the
Markdown output is posted as a PR comment; locally it prints to stdout.

## What it does

1. Reads a Terraform plan (or `helm diff`) from a file (`--input`) or **stdin**.
2. Sends it to Claude (`claude-sonnet-5`) and gets a **structured** result:
   `{has_destructive_or_replacement, risk, summary_markdown}`.
3. **Validates** that object against an inline JSON Schema (`jsonschema`) before
   trusting the `has_destructive_or_replacement` flag.
4. Prints `summary_markdown`. With `--fail-on-destructive`, exits non-zero when
   the validated result flags destructive/replacement changes so CI can require
   human sign-off before `apply`.

## The guardrail (propose → validate → human approve)

Advisory though it is, `explain` keeps the same discipline: we never read the
model's prose to decide whether a change is destructive — we read the **validated
boolean**. A human reviewer then approves or blocks. `explain` has no standalone
`*.schema.json` file (per the repo contract); its schema is defined inline in
`main.py` and still enforced with `jsonschema`.

**The LLM never receives cloud credentials** — only the plan/diff text, which is
first scrubbed for connection strings / secret-looking values (see `redact()`).

## Install

```bash
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
```

## Usage

```bash
# From a file:
terraform -chdir=infra/stacks/aws plan -no-color > /tmp/plan.txt
python ai/explain/main.py --input /tmp/plan.txt

# From stdin (pipe):
terraform -chdir=infra/stacks/gcp plan -no-color | python ai/explain/main.py

# helm diff:
helm diff upgrade idea-board charts/idea-board -f charts/idea-board/values.yaml \
  | python ai/explain/main.py --json

# CI gate: fail (exit 3) if destructive/replacement changes are present.
python ai/explain/main.py --input /tmp/plan.txt --fail-on-destructive
```

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Explained successfully (no destructive changes, or gate not enabled) |
| `2`  | Tool error (empty/missing input, missing `ANTHROPIC_API_KEY`, API failure, schema-invalid result) |
| `3`  | `--fail-on-destructive` set **and** destructive/replacement changes detected |
