"""SQLAlchemy 2.x ORM models."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Integer, Text, func
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    """Declarative base for all ORM models."""


class Idea(Base):
    """A single idea posted to the board.

    Mirrors the contract table::

        ideas(
            id         BIGSERIAL PRIMARY KEY,
            content    TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )

    The ``BigInteger`` primary key is given an ``Integer`` variant for the
    SQLite dialect so autoincrement works during tests (SQLite only
    autoincrements ``INTEGER PRIMARY KEY``); Postgres still gets BIGSERIAL.
    """

    __tablename__ = "ideas"

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    content: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )

    def __repr__(self) -> str:  # pragma: no cover - debugging aid only
        return f"Idea(id={self.id!r}, content={self.content!r})"
