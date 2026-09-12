#!/usr/bin/env python3
"""
ai/envgen — turn a plain-English intent into a PROPOSED, guardrailed sizing config.

WHAT IT DOES
------------
Given an intent string such as "cost-sensitive staging" or
"high-availability production", it:
  1. Asks Claude (model `claude-opus-5`, chosen for stronger reasoning) to
     PROPOSE a sizing config drawn from a deliberately CONSTRAINED vocabulary:
        {node_size, node_count, backend_replicas, frontend_replicas,
         hpa_min, hpa_max}
     where node_size is one of the cloud-agnostic t-shirt sizes small|medium|large.
  2. VALIDATES the proposal against envgen.schema.json (jsonschema) AND against
     hard cross-field guardrails (ranges + hpa_min <= replicas <= hpa_max).
  3. RENDERS the validated proposal as a Terraform `.tfvars` snippet and a Helm
     `values` snippet and PRINTS them for a human to review.

It NEVER applies anything. The output is a proposal for a human to paste (after
review) into terraform.tfvars / a Helm values overlay.

THE GUARDRAIL: PROPOSE -> VALIDATE -> APPROVE -> DETERMINISTIC ACTION
--------------------------------------------------------------------
The model only ever PROPOSES. Three independent layers keep it safe:
  - The response is constrained to a JSON Schema (structured outputs).
  - jsonschema re-validates the parsed object (authoritative).
  - Hard-coded guardrails clamp/reject impossible or unsafe combinations
    (e.g. hpa_max < hpa_min, replicas outside the HPA band, out-of-range counts).
Only after all three pass do we render human-readable snippets — and even then
nothing is applied. A human reviews and applies. Because the vocabulary is the
t-shirt size set, the SAME proposal maps identically onto AWS and GCP.

THE LLM NEVER RECEIVES CLOUD CREDENTIALS
----------------------------------------
The only input to the model is the free-text intent string. No cloud keys, no
kubeconfig, no secret store contents are ever sent.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

# Per the shared repo contract, envgen uses Opus (more reasoning) than the other tools.
DEFAULT_MODEL = "claude-opus-5"

_SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "envgen.schema.json")

# ---------------------------------------------------------------------------
# Hard guardrails — enforced in code, independent of what the model returns.
# These mirror (and are stricter than) the schema's min/max, and add the
# cross-field rules a flat JSON Schema cannot express.
# ---------------------------------------------------------------------------
VALID_NODE_SIZES = ("small", "medium", "large")
NODE_COUNT_MIN, NODE_COUNT_MAX = 1, 10
REPLICA_MIN, REPLICA_MAX = 1, 20
HPA_MIN_FLOOR, HPA_MAX_CEILING = 1, 50


def check_guardrails(cfg: dict[str, Any]) -> list[str]:
    """Return a list of guardrail violation messages (empty == all good)."""
    errs: list[str] = []

    if cfg["node_size"] not in VALID_NODE_SIZES:
        errs.append(f"node_size {cfg['node_size']!r} not in {VALID_NODE_SIZES}")
    if not (NODE_COUNT_MIN <= cfg["node_count"] <= NODE_COUNT_MAX):
        errs.append(f"node_count {cfg['node_count']} outside [{NODE_COUNT_MIN},{NODE_COUNT_MAX}]")

    for key in ("backend_replicas", "frontend_replicas"):
        if not (REPLICA_MIN <= cfg[key] <= REPLICA_MAX):
            errs.append(f"{key} {cfg[key]} outside [{REPLICA_MIN},{REPLICA_MAX}]")

    if not (HPA_MIN_FLOOR <= cfg["hpa_min"] <= HPA_MAX_CEILING):
        errs.append(f"hpa_min {cfg['hpa_min']} outside [{HPA_MIN_FLOOR},{HPA_MAX_CEILING}]")
    if not (HPA_MIN_FLOOR <= cfg["hpa_max"] <= HPA_MAX_CEILING):
        errs.append(f"hpa_max {cfg['hpa_max']} outside [{HPA_MIN_FLOOR},{HPA_MAX_CEILING}]")

    # Cross-field logic the schema cannot express.
    if cfg["hpa_max"] < cfg["hpa_min"]:
        errs.append(f"hpa_max ({cfg['hpa_max']}) must be >= hpa_min ({cfg['hpa_min']})")
    # The backend baseline replica count must sit inside the autoscaler band,
    # otherwise the HPA immediately overrides the Deployment's replica count.
    if not (cfg["hpa_min"] <= cfg["backend_replicas"] <= cfg["hpa_max"]):
        errs.append(
            f"backend_replicas ({cfg['backend_replicas']}) must be within the HPA band "
            f"[{cfg['hpa_min']},{cfg['hpa_max']}]"
        )
    return errs


# ---------------------------------------------------------------------------
# JSON helpers (shared shape with the other ai/* tools)
# ---------------------------------------------------------------------------


def strip_for_structured_output(schema: dict[str, Any]) -> dict[str, Any]:
    """Keep only structural keywords the structured-outputs API is guaranteed to accept."""
    keep = {"type", "properties", "items", "required", "additionalProperties", "enum", "anyOf", "oneOf", "allOf"}
    if not isinstance(schema, dict):
        return schema
    out: dict[str, Any] = {}
    for key, value in schema.items():
        if key not in keep:
            continue
        if key == "properties" and isinstance(value, dict):
            out[key] = {k: strip_for_structured_output(v) for k, v in value.items()}
        elif key == "items" and isinstance(value, dict):
            out[key] = strip_for_structured_output(value)
        elif key in ("anyOf", "oneOf", "allOf") and isinstance(value, list):
            out[key] = [strip_for_structured_output(v) for v in value]
        else:
            out[key] = value
    return out


def extract_json_object(text: str) -> dict[str, Any]:
    import re

    if not text:
        raise ValueError("model returned empty text")
    cleaned = text.strip()
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", cleaned, re.DOTALL)
    if fence:
        cleaned = fence.group(1).strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start != -1 and end != -1 and end > start:
            return json.loads(cleaned[start : end + 1])
        raise


# ---------------------------------------------------------------------------
# Claude call
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are a platform engineer sizing a small Kubernetes application called \
"idea-board" (a FastAPI backend, an nginx-served React frontend, and a Postgres database) \
for a single environment.

The operator gives you a short INTENT (e.g. "cost-sensitive staging", "high-availability \
production", "demo for one reviewer"). Propose a sizing configuration that fits the intent.

Rules you MUST follow:
- node_size is a cloud-agnostic t-shirt size: exactly one of "small", "medium", "large".
  (small ~= cheap/dev, medium ~= general production, large ~= heavy/HA.) Never invent a
  concrete machine type — the t-shirt size is mapped per-cloud downstream.
- node_count: integer 1..10.
- backend_replicas, frontend_replicas: integers 1..20.
- hpa_min, hpa_max: integers, 1..50, with hpa_max >= hpa_min, and the backend baseline
  (backend_replicas) MUST fall within [hpa_min, hpa_max].
- Cost-sensitive / staging / demo intents -> favour small size and low counts (often
  node_count 1, replicas 1, tight HPA band). High-availability / production intents ->
  favour medium/large, >=2 of everything, and headroom in hpa_max.

Respond with ONLY a single JSON object, no prose and no markdown fences, matching exactly \
this JSON Schema (all fields required, no extra fields):

%s"""


def propose_config(intent: str, schema: dict[str, Any], model: str, max_tokens: int) -> dict[str, Any]:
    import anthropic

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment
    system = SYSTEM_PROMPT % json.dumps(schema, indent=2)
    user = f"Intent: {intent!r}\n\nPropose the sizing configuration as JSON."

    try:
        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"format": {"type": "json_schema", "schema": strip_for_structured_output(schema)}},
        )
    except (TypeError, anthropic.BadRequestError):
        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )

    if getattr(response, "stop_reason", None) == "refusal":
        raise RuntimeError("model refused to answer (stop_reason=refusal)")

    text = next((b.text for b in response.content if getattr(b, "type", None) == "text"), "")
    return extract_json_object(text)


# ---------------------------------------------------------------------------
# Rendering (deterministic — this is the "tool" that runs after human approval)
# ---------------------------------------------------------------------------


def render_tfvars(cfg: dict[str, Any], intent: str) -> str:
    return (
        "# ---- terraform.tfvars (cluster sizing) -------------------------------\n"
        f"# PROPOSED by ai/envgen for intent: {intent!r}\n"
        "# REVIEW before `terraform apply`. node_size is mapped to a concrete\n"
        "# machine type inside each cloud module (AWS/GCP).\n"
        f'node_size  = "{cfg["node_size"]}"\n'
        f"node_count = {cfg['node_count']}\n"
    )


def render_helm_values(cfg: dict[str, Any], intent: str) -> str:
    return (
        "# ---- values-<cloud> overlay (Helm) -----------------------------------\n"
        f"# PROPOSED by ai/envgen for intent: {intent!r}\n"
        "# REVIEW before `helm upgrade --install`.\n"
        "backend:\n"
        f"  replicas: {cfg['backend_replicas']}\n"
        "frontend:\n"
        f"  replicas: {cfg['frontend_replicas']}\n"
        "hpa:\n"
        "  enabled: true\n"
        f"  min: {cfg['hpa_min']}\n"
        f"  max: {cfg['hpa_max']}\n"
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ai-envgen",
        description="Propose a guardrailed, cloud-agnostic sizing config from a plain-English intent. Never auto-applied.",
    )
    p.add_argument("intent", nargs="?", help='Intent string, e.g. "cost-sensitive staging".')
    p.add_argument("--intent", dest="intent_opt", default=None, help="Alternative way to pass the intent.")
    p.add_argument("--model", default=DEFAULT_MODEL, help=f"Claude model id (default: {DEFAULT_MODEL}).")
    p.add_argument("--max-tokens", type=int, default=1024, help="max_tokens for the model response (default: 1024).")
    p.add_argument("--json", action="store_true", help="Also print the validated proposal as JSON.")
    p.add_argument("--format", choices=["all", "tfvars", "helm"], default="all", help="Which snippet(s) to render (default: all).")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    intent = args.intent_opt or args.intent
    if not intent or not intent.strip():
        print("[error] an intent string is required (positional or --intent).", file=sys.stderr)
        return 2
    intent = intent.strip()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("[error] ANTHROPIC_API_KEY is not set; cannot contact Claude.", file=sys.stderr)
        return 2

    with open(_SCHEMA_PATH, "r", encoding="utf-8") as fh:
        schema = json.load(fh)

    # 1. PROPOSE.
    try:
        cfg = propose_config(intent, schema, args.model, args.max_tokens)
    except Exception as exc:
        print(f"[error] failed to obtain a proposal from Claude: {exc}", file=sys.stderr)
        return 2

    # 2. VALIDATE — jsonschema first (authoritative), then hard guardrails.
    try:
        from jsonschema import Draft202012Validator

        Draft202012Validator(schema).validate(cfg)
    except Exception as exc:
        print(f"[error] proposal failed schema validation (rejected): {exc}", file=sys.stderr)
        print(f"[error] raw proposal was: {cfg!r}", file=sys.stderr)
        return 2

    violations = check_guardrails(cfg)
    if violations:
        print("[error] proposal REJECTED by hard guardrails:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        print(f"[error] raw proposal was: {cfg!r}", file=sys.stderr)
        return 2

    # 3. RENDER for human approval. NOTHING is applied.
    print(f"# ai/envgen proposal for intent: {intent!r}")
    print(f"# node_size={cfg['node_size']} node_count={cfg['node_count']} "
          f"backend_replicas={cfg['backend_replicas']} frontend_replicas={cfg['frontend_replicas']} "
          f"hpa=[{cfg['hpa_min']},{cfg['hpa_max']}]")
    print("# >>> REVIEW and apply manually. This tool never applies changes. <<<\n")

    if args.format in ("all", "tfvars"):
        print(render_tfvars(cfg, intent))
    if args.format in ("all", "helm"):
        print(render_helm_values(cfg, intent))

    if args.json:
        print(json.dumps(cfg, indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
