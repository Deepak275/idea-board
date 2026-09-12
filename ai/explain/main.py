#!/usr/bin/env python3
"""
ai/explain — plain-English explainer for `terraform plan` / `helm diff` output.

WHAT IT DOES
------------
Reads a Terraform plan (or `helm diff`) as text from a file or stdin, sends it to
Claude (model `claude-sonnet-5`), and prints a plain-English Markdown summary that
explicitly flags DESTRUCTIVE / REPLACEMENT changes (resource destroy, force-new/
replace, DB or storage deletion, etc.). In CI this Markdown is posted as a PR
comment; locally it just prints.

THE GUARDRAIL: PROPOSE -> VALIDATE -> (HUMAN) APPROVE
----------------------------------------------------
Even though this tool is advisory (it explains, it does not act), it follows the
same discipline as the rest of ai/*: the model returns a STRUCTURED object
{has_destructive_or_replacement, risk, summary_markdown} which is VALIDATED
against an inline JSON Schema with jsonschema before we trust the
`has_destructive_or_replacement` flag. We never parse the model's prose to decide
whether a change is destructive — we read the validated boolean. A human reviewer
then approves or blocks the plan; with `--fail-on-destructive` the process exits
non-zero so a CI job can require explicit human sign-off before apply.

THE LLM NEVER RECEIVES CLOUD CREDENTIALS
----------------------------------------
Only the plan/diff text is sent. Terraform plan output can contain resource
attributes; secret-looking values are redacted before sending (see `redact`).
No cloud keys, kubeconfig, or secret-store contents are ever forwarded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

# Per the shared repo contract, explain (like healthcheck) uses Sonnet.
DEFAULT_MODEL = "claude-sonnet-5"

# Inline schema — explain has no standalone *.schema.json file (per the repo
# contract), but we still validate the model's structured output against a schema.
RESULT_SCHEMA: dict[str, Any] = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "title": "PlanExplanation",
    "type": "object",
    "additionalProperties": False,
    "required": ["has_destructive_or_replacement", "risk", "summary_markdown"],
    "properties": {
        "has_destructive_or_replacement": {
            "type": "boolean",
            "description": "true if the plan destroys or replaces (force-new) any resource, or otherwise causes data loss.",
        },
        "risk": {
            "type": "string",
            "enum": ["none", "low", "medium", "high"],
            "description": "Overall risk level of applying this plan.",
        },
        "summary_markdown": {
            "type": "string",
            "minLength": 1,
            "description": "Plain-English Markdown summary suitable for a PR comment.",
        },
    },
}

# ---------------------------------------------------------------------------
# Secret redaction (defence in depth — LLM never gets credentials)
# ---------------------------------------------------------------------------
_CONN_STRING_RE = re.compile(r"(?P<scheme>[a-zA-Z0-9+.\-]+://)(?P<user>[^:/@\s]+):(?P<pw>[^@/\s]+)@")
_SECRET_KV_RE = re.compile(
    r"(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"
    r"(\s*[:=]\s*\"?|\"\s*[:=]\s*\"?)([^\s\"',]+)"
)


def redact(text: str) -> str:
    if not text:
        return text
    text = _CONN_STRING_RE.sub(lambda m: f"{m.group('scheme')}{m.group('user')}:***@", text)
    text = _SECRET_KV_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}***", text)
    return text


# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------


def strip_for_structured_output(schema: dict[str, Any]) -> dict[str, Any]:
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

SYSTEM_PROMPT = """You are an infrastructure reviewer. You are given the raw text of a \
`terraform plan` (or `helm diff`) for the "idea-board" application's cloud infrastructure \
(VPC/network, a Kubernetes cluster, and a managed Postgres database).

Explain, in clear plain English, what the plan will do. Your MOST IMPORTANT job is to \
surface anything DESTRUCTIVE or dangerous so a human reviewer notices it:
  - resources being destroyed ("-" / "will be destroyed"),
  - resources being REPLACED / force-new ("-/+", "must be replaced", "forces replacement"),
  - anything that could cause data loss (database/volume/storage destroy or replace),
  - IAM / networking changes that could cut access.
Also briefly note the benign creates/updates.

Set has_destructive_or_replacement=true if the plan destroys or replaces ANY resource or \
risks data loss. Choose risk: "high" for data-loss/DB replacement, "medium" for other \
replacements or networking/IAM changes, "low" for in-place updates only, "none" for a \
no-op plan.

Write summary_markdown as GitHub-flavoured Markdown suitable for a PR comment: a one-line \
headline, a "Destructive / replacement changes" section (say "None detected." if there are \
none), and a short "Other changes" section. Reference specific resource addresses.

Respond with ONLY a single JSON object, no prose outside it and no markdown fences, matching \
exactly this JSON Schema (all fields required, no extra fields):

%s"""


def explain_plan(plan_text: str, model: str, max_tokens: int) -> dict[str, Any]:
    import anthropic

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment
    system = SYSTEM_PROMPT % json.dumps(RESULT_SCHEMA, indent=2)
    user = "Here is the plan/diff to explain:\n\n" + plan_text

    try:
        response = client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
            output_config={"format": {"type": "json_schema", "schema": strip_for_structured_output(RESULT_SCHEMA)}},
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
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ai-explain",
        description="Explain a terraform plan / helm diff in plain English and flag destructive changes.",
    )
    p.add_argument("-i", "--input", default=None, help="Path to the plan/diff text file. Reads stdin if omitted.")
    p.add_argument("--model", default=DEFAULT_MODEL, help=f"Claude model id (default: {DEFAULT_MODEL}).")
    p.add_argument("--max-tokens", type=int, default=4096, help="max_tokens for the model response (default: 4096).")
    p.add_argument(
        "--fail-on-destructive",
        action="store_true",
        help="Exit non-zero (3) when the (validated) result flags destructive/replacement changes, so CI can require sign-off.",
    )
    p.add_argument("--json", action="store_true", help="Also print the validated result object as JSON.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # 1. READ input (file or stdin). Never truncate — send the whole plan.
    if args.input:
        try:
            with open(args.input, "r", encoding="utf-8") as fh:
                plan_text = fh.read()
        except OSError as exc:
            print(f"[error] could not read {args.input}: {exc}", file=sys.stderr)
            return 2
    else:
        plan_text = sys.stdin.read()

    if not plan_text.strip():
        print("[error] no plan/diff text provided (empty input).", file=sys.stderr)
        return 2

    # Scrub credentials BEFORE the text leaves the process toward the LLM.
    plan_text = redact(plan_text)

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("[error] ANTHROPIC_API_KEY is not set; cannot contact Claude.", file=sys.stderr)
        return 2

    # 2. PROPOSE.
    try:
        result = explain_plan(plan_text, args.model, args.max_tokens)
    except Exception as exc:
        print(f"[error] failed to obtain an explanation from Claude: {exc}", file=sys.stderr)
        return 2

    # 3. VALIDATE — trust the boolean only after schema validation.
    try:
        from jsonschema import Draft202012Validator

        Draft202012Validator(RESULT_SCHEMA).validate(result)
    except Exception as exc:
        print(f"[error] explanation failed schema validation: {exc}", file=sys.stderr)
        print(f"[error] raw result was: {result!r}", file=sys.stderr)
        return 2

    # 4. REPORT (this Markdown is what CI posts as a PR comment).
    print(result["summary_markdown"])

    if args.json:
        print("\n```json")
        print(json.dumps({k: v for k, v in result.items() if k != "summary_markdown"}, indent=2))
        print("```")

    if args.fail_on_destructive and result["has_destructive_or_replacement"]:
        print(
            "\n[gate] destructive/replacement changes detected — human sign-off required before apply.",
            file=sys.stderr,
        )
        return 3

    return 0


if __name__ == "__main__":
    sys.exit(main())
