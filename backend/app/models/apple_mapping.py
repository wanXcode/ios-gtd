import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint, func
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
    last_synced_task_version: Mapped[int | None]
    last_seen_apple_modified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    sync_state: Mapped[str] = mapped_column(String(32), default=SyncState.ACTIVE.value, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)
