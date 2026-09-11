"""Pydantic (v2) request/response schemas."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class IdeaCreate(BaseModel):
    """Request body for creating an idea."""

    content: str = Field(
        ...,
        min_length=1,
        max_length=10_000,
        description="The free-text content of the idea.",
    )


class IdeaRead(BaseModel):
    """Serialized representation of a persisted idea."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    content: str
    created_at: datetime


class HealthResponse(BaseModel):
    """Simple status payload for the liveness/readiness probes."""

    status: str
