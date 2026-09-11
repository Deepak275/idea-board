"""API tests for the Idea Board backend.

These run against a throwaway SQLite database so the suite needs no Postgres
server. The production code path is dialect-agnostic; SQLite is used here only
as a lightweight stand-in. ``DATABASE_URL`` is set *before* importing the app
so ``app.db`` builds its engine against the test database.

If a real Postgres is desired (e.g. via testcontainers), export
``DATABASE_URL`` pointing at it before running pytest and the same tests run
unchanged against Postgres.
"""

from __future__ import annotations

import os
import tempfile

# ---------------------------------------------------------------------------
# Configure the test database URL BEFORE importing any app module, because
# app.db reads DATABASE_URL and builds the engine at import time.
# ---------------------------------------------------------------------------
if "DATABASE_URL" not in os.environ:
    _TMP = tempfile.NamedTemporaryFile(prefix="idea_board_test_", suffix=".db", delete=False)
    _TMP.close()
    os.environ["DATABASE_URL"] = f"sqlite:///{_TMP.name}"

import pytest
from app.db import engine
from app.main import app
from app.models import Base
from fastapi.testclient import TestClient


@pytest.fixture(autouse=True)
def _fresh_schema():
    """Recreate the schema before each test for isolation."""

    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture()
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client


def test_healthz_does_not_touch_db(client: TestClient) -> None:
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_checks_db(client: TestClient) -> None:
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_list_ideas_empty(client: TestClient) -> None:
    response = client.get("/api/ideas")
    assert response.status_code == 200
    assert response.json() == []


def test_create_idea_returns_201_with_created_row(client: TestClient) -> None:
    response = client.post("/api/ideas", json={"content": "Ship a cloud-agnostic app"})
    assert response.status_code == 201

    body = response.json()
    assert body["id"] >= 1
    assert body["content"] == "Ship a cloud-agnostic app"
    assert body.get("created_at")


def test_create_then_list_roundtrip(client: TestClient) -> None:
    client.post("/api/ideas", json={"content": "first"})
    client.post("/api/ideas", json={"content": "second"})

    response = client.get("/api/ideas")
    assert response.status_code == 200

    contents = [item["content"] for item in response.json()]
    assert set(contents) == {"first", "second"}
    assert len(contents) == 2


def test_create_idea_rejects_empty_content(client: TestClient) -> None:
    response = client.post("/api/ideas", json={"content": ""})
    assert response.status_code == 422


def test_create_idea_rejects_missing_field(client: TestClient) -> None:
    response = client.post("/api/ideas", json={})
    assert response.status_code == 422
