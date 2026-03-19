import uuid
from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base
from app.models.enums import SyncState


class AppleReminderMapping(Base):
    __tablename__ = "apple_reminder_mappings"
    __table_args__ = (UniqueConstraint("apple_reminder_id", name="uq_apple_reminder_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    task_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tasks.id", ondelete="CASCADE"), nullable=False)
    apple_reminder_id: Mapped[str] = mapped_column(Text(), nullable=False)
    apple_list_id: Mapped[str | None] = mapped_column(Text())
    apple_calendar_id: Mapped[str | None] = mapped_column(Text())
    last_synced_task_version: Mapped[int | None] = mapped_column(Integer)
    last_seen_apple_modified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    sync_state: Mapped[str] = mapped_column(String(32), default=SyncState.ACTIVE.value, nullable=False)
    pending_operation: Mapped[str | None] = mapped_column(String(32))
    last_push_change_id: Mapped[int | None] = mapped_column(Integer)
    bridge_updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_ack_status: Mapped[str | None] = mapped_column(String(32))
    last_error_code: Mapped[str | None] = mapped_column(String(64))
    last_error_message: Mapped[str | None] = mapped_column(Text())
    is_deleted_on_apple: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)
