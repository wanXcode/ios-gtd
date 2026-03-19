import uuid
from datetime import datetime

from sqlalchemy import DateTime, Integer, JSON, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class SyncBridgeState(Base):
    __tablename__ = "sync_bridge_states"
    __table_args__ = (UniqueConstraint("bridge_id", name="uq_sync_bridge_state_bridge_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    bridge_id: Mapped[str] = mapped_column(String(255), nullable=False)
    backend_cursor: Mapped[str | None] = mapped_column(Text())
    last_pull_cursor: Mapped[str | None] = mapped_column(Text())
    last_push_cursor: Mapped[str | None] = mapped_column(Text())
    last_acked_change_id: Mapped[int | None] = mapped_column(Integer)
    last_seen_change_id: Mapped[int | None] = mapped_column(Integer)
    last_pull_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_pull_succeeded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_push_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_push_succeeded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_ack_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_ack_succeeded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error_code: Mapped[str | None] = mapped_column(String(64))
    last_error_message: Mapped[str | None] = mapped_column(Text())
    metadata_json: Mapped[dict | None] = mapped_column("metadata", JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)
