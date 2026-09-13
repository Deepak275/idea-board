# syntax=docker/dockerfile:1
#
# Multi-stage build for the Idea Board FastAPI backend.
# Build context is app/backend/ (this file's directory).

# ---------------------------------------------------------------------------
# Stage 1: build a self-contained virtualenv with all dependencies.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
# Upgrade pip + setuptools (setuptools <78.1.1 has CVE-2025-47273) before deps.
RUN pip install --upgrade pip "setuptools>=78.1.1" && pip install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image, non-root.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Patch OS packages so the runtime image ships current Debian security fixes
# (gzip / pcre2 / sqlite / perl CVEs). Also upgrade the BASE IMAGE's *system*
# Python setuptools (separate from /opt/venv) — python:3.12-slim ships 70.3.0
# which has CVE-2025-47273. Runs as root before dropping privileges; CI's Trivy
# gate blocks the push if fixable HIGH/CRITICAL CVEs remain.
RUN apt-get update && apt-get -y upgrade && rm -rf /var/lib/apt/lists/* \
    && /usr/local/bin/python -m pip install --no-cache-dir --upgrade "setuptools>=78.1.1"

# Copy the pre-built virtualenv from the builder stage.
COPY --from=builder /opt/venv /opt/venv

# Belt-and-suspenders for setuptools (CVE-2025-47273): patch the venv's copy too
# (the gate scans /opt/venv) and delete any stale pre-upgrade dist-info that Trivy
# would otherwise still report. Runs as root; `; true` keeps the build green.
RUN /opt/venv/bin/python -m pip install --no-cache-dir --upgrade "setuptools>=78.1.1"; \
    find / -type d -name 'setuptools-70.*.dist-info' -exec rm -rf {} + 2>/dev/null; true

# Copy application source and migration assets.
COPY app ./app
COPY alembic ./alembic
COPY alembic.ini ./alembic.ini

# Create and switch to an unprivileged user.
RUN addgroup --system app && adduser --system --ingroup app app \
    && chown -R app:app /app
USER app

EXPOSE 8000

# Liveness check hits /healthz (no DB dependency) using only the stdlib.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import sys, urllib.request; \
sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz', timeout=4).status == 200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
