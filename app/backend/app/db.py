"""Database engine and session management.

Configuration is strictly 12-factor: the connection string comes from the
``DATABASE_URL`` environment variable and nothing else. The expected form is::

    postgresql+psycopg://USER:PASS@HOST:PORT/DBNAME

The SQLite dialect is transparently supported so the test-suite can run
without a real Postgres server; no production code path depends on it.
"""

from __future__ import annotations

import os
from collections.abc import Iterator

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker


def _database_url() -> str:
    """Return the configured ``DATABASE_URL`` or fail fast.

    Failing at import time keeps the container honest: a misconfigured
    deployment crashes immediately instead of serving broken traffic.
    """

    url = os.getenv("DATABASE_URL")
    if not url:
        raise RuntimeError(
            "DATABASE_URL environment variable is required "
            "(form: postgresql+psycopg://USER:PASS@HOST:PORT/DBNAME)"
        )
    return url


DATABASE_URL: str = _database_url()

# SQLite (used only by the test-suite) needs a couple of dialect-specific
# tweaks so it behaves under the FastAPI/TestClient threading model.
_connect_args: dict[str, object] = {}
if DATABASE_URL.startswith("sqlite"):
    _connect_args = {"check_same_thread": False}

# ``pool_pre_ping`` guards against stale connections after a DB failover,
# which matters for the /readyz probe and for long-lived pods.
engine: Engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    future=True,
    connect_args=_connect_args,
)

SessionLocal = sessionmaker(
    bind=engine,
    class_=Session,
    autoflush=False,
    expire_on_commit=False,
    future=True,
)


def get_session() -> Iterator[Session]:
    """FastAPI dependency that yields a scoped SQLAlchemy session."""

    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
