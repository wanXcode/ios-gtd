from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class SyncApplePullRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    cursor: str | None = None
    limit: int = Field(default=100, ge=1, le=500)


class SyncApplePushTask(BaseModel):
    task_id: UUID
    version: int


class SyncApplePushRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    cursor: str | None = None
    tasks: list[SyncApplePushTask] = Field(default_factory=list)


class SyncAppleAckItem(BaseModel):
    task_id: UUID
    remote_id: str | None = None
    version: int
    status: str = "acked"
    apple_modified_at: datetime | None = None


class SyncAppleAckRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    acks: list[SyncAppleAckItem] = Field(default_factory=list)
