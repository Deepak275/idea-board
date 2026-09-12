#!/usr/bin/env python3
"""
ai/healthcheck — AI-assisted post-deploy health verdict for the idea-board app.

WHAT IT DOES
------------
After `helm upgrade --install`, CI runs this module. It:
  1. Collects read-only cluster diagnostics via `kubectl` subprocesses
     (rollout status, pod restart counts, recent events, recent pod logs).
  2. Sends that text to Claude (model `claude-sonnet-5`) and asks for a
     STRUCTURED verdict: {healthy, confidence, reasons, summary}.
  3. Validates the model's JSON against healthcheck.schema.json (jsonschema).
  4. Prints a human-readable summary and exits:
        0  -> healthy   (CI keeps the release)
        1  -> unhealthy (CI runs `helm rollback`)
        2  -> inconclusive / tool error (could not obtain a valid verdict;
              CI should treat this as "not verified" per its own policy)

THE GUARDRAIL: PROPOSE -> VALIDATE -> APPROVE -> DETERMINISTIC ACTION
--------------------------------------------------------------------
The LLM is *advisory only*. It PROPOSES a verdict. We never execute raw model
text. The proposal is VALIDATED against a strict JSON Schema, and the only thing
that actually happens as a result is a deterministic branch on `healthy` /
exit code inside CI (the "human-approved tool" here is the reviewed CI pipeline
that decides to roll back). If the model returns malformed JSON, hallucinates
an extra field, or the API call fails, validation fails closed and we exit 2 —
we never guess a verdict.

THE LLM NEVER RECEIVES CLOUD CREDENTIALS
----------------------------------------
This tool only ever sends Claude the *text output of `kubectl`* (events, logs,
rollout/pod status). It never reads or forwards:
  - the kubeconfig or any cloud auth token,
  - the ANTHROPIC_API_KEY beyond using it to authenticate the SDK client,
  - Kubernetes Secrets (we never `kubectl get secret -o yaml`).
As defence in depth, pod logs are scrubbed (see `redact`) for connection
strings / password-like tokens before they are sent to the model, because
backend logs can incidentally echo a DATABASE_URL.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Per the shared repo contract, the health-check + explain features use Sonnet.
DEFAULT_MODEL = "claude-sonnet-5"

_SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "healthcheck.schema.json")

# Exit codes (documented above and in the README).
EXIT_HEALTHY = 0
EXIT_UNHEALTHY = 1
EXIT_ERROR = 2


# ---------------------------------------------------------------------------
# Secret redaction (defence in depth — LLM never gets credentials)
# ---------------------------------------------------------------------------

# postgresql+psycopg://user:secret@host:5432/db  ->  ...://user:***@host:5432/db
_CONN_STRING_RE = re.compile(r"(?P<scheme>[a-zA-Z0-9+.\-]+://)(?P<user>[^:/@\s]+):(?P<pw>[^@/\s]+)@")
# KEY=value / "KEY": "value" style leaks for common secret key names.
_SECRET_KV_RE = re.compile(
    r"(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"
    r"(\s*[:=]\s*|\"\s*:\s*\")([^\s\"',]+)"
)


def redact(text: str) -> str:
    """Mask connection-string passwords and obvious secret key/value pairs."""
    if not text:
        return text
    text = _CONN_STRING_RE.sub(lambda m: f"{m.group('scheme')}{m.group('user')}:***@", text)
    text = _SECRET_KV_RE.sub(lambda m: f"{m.group(1)}{m.group(2)}***", text)
    return text


# ---------------------------------------------------------------------------
# kubectl collection (read-only)
# ---------------------------------------------------------------------------


def run_kubectl(kubectl: str, args: list[str], context: str | None, timeout: int) -> str:
    """
    Run a read-only kubectl command and return combined stdout/stderr as text.

    We never raise on a non-zero exit here: a failed sub-command (e.g. no pods
    yet) is itself a useful diagnostic signal for the model, so we capture the
    stderr and label it rather than aborting the whole collection.
    """
    cmd = [kubectl]
    if context:
        cmd += ["--context", context]
    cmd += args
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return f"[error] `{kubectl}` executable not found on PATH"
    except subprocess.TimeoutExpired:
        return f"[error] command timed out after {timeout}s: {' '.join(cmd)}"
    out = proc.stdout or ""
    err = proc.stderr or ""
    if proc.returncode != 0 and not out:
        return f"[exit {proc.returncode}] {err.strip()}"
    if err.strip():
        out = f"{out}\n[stderr] {err.strip()}"
    return out.strip() or "[empty]"


def collect_diagnostics(args: argparse.Namespace) -> str:
    """Gather all read-only signals and return one labelled text blob."""
    ns = args.namespace
    sections: list[tuple[str, str]] = []

    for label, deploy in (("backend", args.backend_deployment), ("frontend", args.frontend_deployment)):
        # Rollout status. --timeout keeps it from blocking; a small value means
        # "if it hasn't converged almost immediately, report that".
        sections.append(
            (
                f"kubectl rollout status ({label} deployment/{deploy})",
                run_kubectl(
                    args.kubectl,
                    ["rollout", "status", f"deployment/{deploy}", "-n", ns, f"--timeout={args.rollout_timeout}s"],
                    args.context,
                    args.timeout,
                ),
            )
        )

    sections.append(
        (
            "kubectl get deployments (wide)",
            run_kubectl(args.kubectl, ["get", "deployments", "-n", ns, "-o", "wide"], args.context, args.timeout),
        )
    )
    # Pod list includes the RESTARTS column -> pod restart counts.
    sections.append(
        (
            "kubectl get pods (wide, includes RESTARTS)",
            run_kubectl(args.kubectl, ["get", "pods", "-n", ns, "-o", "wide"], args.context, args.timeout),
        )
    )
    sections.append(
        (
            "kubectl get events (sorted by lastTimestamp)",
            run_kubectl(
                args.kubectl,
                ["get", "events", "-n", ns, "--sort-by=.lastTimestamp"],
                args.context,
                args.timeout,
            ),
        )
    )

    for label, deploy in (("backend", args.backend_deployment), ("frontend", args.frontend_deployment)):
        raw = run_kubectl(
            args.kubectl,
            ["logs", f"deployment/{deploy}", "-n", ns, f"--tail={args.log_lines}", "--all-containers=true", "--prefix=true"],
            args.context,
            args.timeout,
        )
        # Scrub credentials BEFORE the text ever leaves the process toward the LLM.
        sections.append((f"recent {label} logs (last {args.log_lines} lines, secrets redacted)", redact(raw)))

    blob = "\n\n".join(f"===== {title} =====\n{body}" for title, body in sections)
    return blob


# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------


def strip_for_structured_output(schema: dict[str, Any]) -> dict[str, Any]:
    """
    Return a copy of `schema` keeping only keywords the Messages API
    `output_config.format` (structured outputs) is guaranteed to accept.

    We keep structural keywords (type/enum/properties/items/required/
    additionalProperties) and drop validation-only / annotation keywords
    (minimum, maximum, minItems, patterns, titles, $schema, ...). The FULL
    schema — including those numeric/range guardrails — is still enforced
    afterwards by jsonschema, which is the authoritative validation layer.
    """
    keep_container = {"type", "properties", "items", "required", "additionalProperties", "enum", "anyOf", "oneOf", "allOf"}
    if not isinstance(schema, dict):
        return schema
    out: dict[str, Any] = {}
    for key, value in schema.items():
        if key not in keep_container:
            continue
        if key == "properties" and isinstance(value, dict):
            out[key] = {k: strip_for_structured_output(v) for k, v in value.items()}
        elif key in ("items",) and isinstance(value, dict):
            out[key] = strip_for_structured_output(value)
        elif key in ("anyOf", "oneOf", "allOf") and isinstance(value, list):
            out[key] = [strip_for_structured_output(v) for v in value]
        else:
            out[key] = value
    return out


def extract_json_object(text: str) -> dict[str, Any]:
    """Parse a JSON object out of model text, tolerating markdown fences."""
    if not text:
        raise ValueError("model returned empty text")
    cleaned = text.strip()
    # Strip a leading/trailing ```json ... ``` fence if present.
    fence = re.match(r"^```(?:json)?\s*(.*?)\s*```$", cleaned, re.DOTALL)
    if fence:
        cleaned = fence.group(1).strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        # Fall back to the widest {...} span.
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start != -1 and end != -1 and end > start:
            return json.loads(cleaned[start : end + 1])
        raise


# ---------------------------------------------------------------------------
# Claude call
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You are a senior Site Reliability Engineer performing a post-deployment \
health check on a small Kubernetes application called "idea-board" (a FastAPI backend, \
an nginx-served React frontend, and a Postgres database).

You will receive read-only diagnostics collected with kubectl: rollout status, deployment \
and pod listings (including RESTARTS), recent cluster events, and recent (secret-redacted) \
pod logs.

Decide whether the deployment is HEALTHY and safe to keep, or UNHEALTHY and should be \
rolled back. Treat as UNHEALTHY: CrashLoopBackOff / ImagePullBackOff / ErrImagePull, \
pods not Ready, rollouts that did not converge, repeated container restarts, OOMKilled, \
readiness/liveness probe failures, or error/exception spikes in logs. Transient warnings \
that have since recovered are not, by themselves, unhealthy.

Respond with ONLY a single JSON object, no prose and no markdown fences, matching exactly \
this JSON Schema (all fields required, no extra fields):

%s

Base every reason on concrete evidence from the diagnostics (name the pod, the restart \
count, the event message, or the log line). If the evidence is thin or ambiguous, say so \
and lower your confidence."""


def get_verdict(diagnostics: str, schema: dict[str, Any], model: str, max_tokens: int) -> dict[str, Any]:
    """Call Claude and return the parsed (not-yet-validated) verdict dict."""
    import anthropic  # imported here so --print-context works without the SDK installed

    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment
    system = SYSTEM_PROMPT % json.dumps(schema, indent=2)
    user = (
        "Here are the read-only kubectl diagnostics for the idea-board deployment. "
        "Return your structured verdict.\n\n" + diagnostics
    )

    # Preferred path: constrain the response to our schema via structured outputs.
    # If the installed SDK / model does not support output_config, fall back to a
    # plain request (the system prompt already demands schema-shaped JSON). Either
    # way, jsonschema below is the authoritative validation gate.
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
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ai-healthcheck",
        description="AI-assisted post-deploy health verdict for idea-board (exit 0 healthy / 1 unhealthy / 2 error).",
    )
    p.add_argument("-n", "--namespace", default="idea-board", help="Kubernetes namespace (default: idea-board).")
    p.add_argument("--backend-deployment", default="idea-board-backend", help="Backend Deployment name.")
    p.add_argument("--frontend-deployment", default="idea-board-frontend", help="Frontend Deployment name.")
    p.add_argument("--context", default=None, help="kubectl context to use (optional).")
    p.add_argument("--kubectl", default=os.environ.get("KUBECTL", "kubectl"), help="kubectl binary (default: kubectl).")
    p.add_argument("--log-lines", type=int, default=100, help="Lines of recent pod logs to collect (default: 100).")
    p.add_argument("--timeout", type=int, default=30, help="Per-kubectl-command timeout in seconds (default: 30).")
    p.add_argument("--rollout-timeout", type=int, default=15, help="`kubectl rollout status` --timeout seconds (default: 15).")
    p.add_argument("--model", default=DEFAULT_MODEL, help=f"Claude model id (default: {DEFAULT_MODEL}).")
    p.add_argument("--max-tokens", type=int, default=2048, help="max_tokens for the model response (default: 2048).")
    p.add_argument("--json", action="store_true", help="Print the validated verdict as JSON (in addition to the summary).")
    p.add_argument(
        "--print-context",
        action="store_true",
        help="Only collect and print the (redacted) diagnostics that WOULD be sent to Claude, then exit 0. Does not call the API.",
    )
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # 1. COLLECT (read-only, credentials scrubbed).
    diagnostics = collect_diagnostics(args)

    if args.print_context:
        print(diagnostics)
        return EXIT_HEALTHY

    # The API key is the ONLY secret this tool needs. Fail early with a clear
    # message rather than a cryptic SDK error deep in the call.
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("[error] ANTHROPIC_API_KEY is not set; cannot contact Claude.", file=sys.stderr)
        return EXIT_ERROR

    with open(_SCHEMA_PATH, "r", encoding="utf-8") as fh:
        schema = json.load(fh)

    # 2. PROPOSE — ask the model for a structured verdict.
    try:
        verdict = get_verdict(diagnostics, schema, args.model, args.max_tokens)
    except Exception as exc:  # network, parse, refusal, SDK errors -> inconclusive
        print(f"[error] failed to obtain a verdict from Claude: {exc}", file=sys.stderr)
        return EXIT_ERROR

    # 3. VALIDATE — jsonschema is the authoritative gate. Fail closed.
    try:
        from jsonschema import Draft202012Validator

        Draft202012Validator(schema).validate(verdict)
    except Exception as exc:
        print(f"[error] model verdict failed schema validation (treating as inconclusive): {exc}", file=sys.stderr)
        print(f"[error] raw verdict was: {verdict!r}", file=sys.stderr)
        return EXIT_ERROR

    # 4. REPORT + deterministic exit code (the CI gate acts on THIS, not on prose).
    healthy = bool(verdict["healthy"])
    status = "HEALTHY" if healthy else "UNHEALTHY"
    print(f"idea-board health check: {status} (confidence {verdict['confidence']:.2f})")
    print(f"summary: {verdict['summary']}")
    print("reasons:")
    for reason in verdict["reasons"]:
        print(f"  - {reason}")

    if args.json:
        print("\n" + json.dumps(verdict, indent=2))

    return EXIT_HEALTHY if healthy else EXIT_UNHEALTHY


if __name__ == "__main__":
    sys.exit(main())
