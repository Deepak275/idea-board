"""FastAPI application: routes, CORS, and health/readiness probes.

Endpoints (per the shared contract):
    GET  /api/ideas  -> JSON array of ideas
    POST /api/ideas  -> {"content": "..."} -> 201 with the created idea
    GET  /healthz     -> liveness (never touches the database)
    GET  /readyz      -> readiness (verifies database connectivity)

This service is deliberately cloud-agnostic: the only external dependency is
a Postgres database addressed via the ``DATABASE_URL`` environment variable.
"""

from __future__ import annotations

import logging
import os

from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.db import engine, get_session
from app.models import Idea
from app.schemas import HealthResponse, IdeaCreate, IdeaRead

logger = logging.getLogger("idea_board")


def _cors_origins() -> list[str]:
    """Frontend origins allowed by CORS, configured via ``CORS_ORIGINS``.

    Comma-separated list; defaults cover the Vite dev server (:5173) and the
    nginx-served production frontend (:80 / bare localhost).
    """

    raw = os.getenv(
        "CORS_ORIGINS",
        "http://localhost,http://localhost:80,http://localhost:5173",
    )
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


app = FastAPI(
    title="Idea Board API",
    version="1.0.0",
    description="A tiny cloud-agnostic idea board.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get(
    "/healthz",
    response_model=HealthResponse,
    tags=["health"],
    summary="Liveness probe",
)
def healthz() -> HealthResponse:
    """Liveness check. Intentionally does NOT touch the database so that a
    transient DB outage does not cause the pod to be killed and restarted."""

    return HealthResponse(status="ok")


@app.get(
    "/readyz",
    response_model=HealthResponse,
    tags=["health"],
    summary="Readiness probe",
)
def readyz() -> HealthResponse:
    """Readiness check. Verifies the database is reachable so traffic is only
    routed to pods that can actually serve requests."""

    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:  # pragma: no cover - exercised via probe
        logger.warning("Readiness check failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="database unavailable",
        ) from exc
    return HealthResponse(status="ready")


@app.get(
    "/api/ideas",
    response_model=list[IdeaRead],
    tags=["ideas"],
    summary="List ideas (newest first)",
)
def list_ideas(session: Session = Depends(get_session)) -> list[Idea]:
    """Return all ideas, newest first."""

    result = session.execute(
        select(Idea).order_by(Idea.created_at.desc(), Idea.id.desc())
    )
    return list(result.scalars().all())


@app.post(
    "/api/ideas",
    response_model=IdeaRead,
    status_code=status.HTTP_201_CREATED,
    tags=["ideas"],
    summary="Create an idea",
)
def create_idea(
    payload: IdeaCreate,
    session: Session = Depends(get_session),
) -> Idea:
    """Persist a new idea and return it with its server-assigned fields."""

    idea = Idea(content=payload.content)
    session.add(idea)
    session.commit()
    session.refresh(idea)
    return idea
