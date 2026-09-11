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
RUN pip install --upgrade pip && pip install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: minimal runtime image, non-root.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# Copy the pre-built virtualenv from the builder stage.
COPY --from=builder /opt/venv /opt/venv

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
