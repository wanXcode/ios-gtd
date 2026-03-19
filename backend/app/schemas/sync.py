from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class SyncApplePullRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    cursor: str | None = None
    limit: int = Field(default=100, ge=1, le=500)
    changes: list["SyncApplePullChange"] = Field(default_factory=list)


class SyncApplePullChangePayload(BaseModel):
    title: str = Field(min_length=1, max_length=255)
    note: str | None = None
    is_completed: bool = False
    due_at: datetime | None = None
    remind_at: datetime | None = None
    is_all_day_due: bool = False
    priority: int | None = Field(default=None, ge=1, le=9)
    list_name: str | None = None


class SyncApplePullChange(BaseModel):
    change_type: str = Field(pattern="^(upsert|delete)$")
    apple_reminder_id: str = Field(min_length=1)
    apple_list_id: str | None = None
    apple_calendar_id: str | None = None
    apple_modified_at: datetime | None = None
    payload: SyncApplePullChangePayload | None = None


class SyncApplePushTask(BaseModel):
    task_id: UUID
    version: int


class SyncApplePushRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    cursor: str | None = None
    tasks: list[SyncApplePushTask] = Field(default_factory=list)
    limit: int = Field(default=100, ge=1, le=500)


class SyncAppleAckItem(BaseModel):
    task_id: UUID
    remote_id: str | None = None
    version: int
    change_id: int | None = Field(default=None, ge=1)
    status: str = Field(default="success", pattern="^(success|failed|conflict|acked)$")
    apple_modified_at: datetime | None = None
    apple_list_id: str | None = None
    apple_calendar_id: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    retryable: bool = False


class SyncAppleAckRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    acks: list[SyncAppleAckItem] = Field(default_factory=list)


class SyncBridgeStateRead(BaseModel):
    bridge_id: str
    backend_cursor: str | None = None
    last_pull_cursor: str | None = None
    last_push_cursor: str | None = None
    last_acked_change_id: int | None = None
    last_failed_change_id: int | None = None
    last_seen_change_id: int | None = None
    last_pull_started_at: datetime | None = None
    last_pull_succeeded_at: datetime | None = None
    last_push_started_at: datetime | None = None
    last_push_succeeded_at: datetime | None = None
    last_ack_started_at: datetime | None = None
    last_ack_succeeded_at: datetime | None = None
    last_error_code: str | None = None
    last_error_message: str | None = None
    metadata: dict | None = None
    created_at: datetime
    updated_at: datetime
