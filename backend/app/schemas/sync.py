from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_serializer

from app.utils_datetime import isoformat_z


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
    change_type: Literal["upsert", "delete"]
    apple_reminder_id: str = Field(min_length=1)
    apple_list_id: str | None = None
    apple_calendar_id: str | None = None
    apple_modified_at: datetime | None = None
    source_record_id: str | None = None
    external_identifier: str | None = None
    payload: SyncApplePullChangePayload | None = None


class SyncApplePushTask(BaseModel):
    task_id: UUID | None = None
    reminder_id: str = Field(min_length=1)
    title: str = Field(min_length=1, max_length=255)
    notes: str | None = None
    due_date: datetime | None = None
    remind_at: datetime | None = None
    is_all_day_due: bool = False
    priority: int | None = Field(default=None, ge=1, le=9)
    list_name: str | None = None
    list_identifier: str | None = None
    external_identifier: str | None = None
    state: Literal["active", "completed", "deleted"]
    fingerprint: dict
    last_modified_at: datetime
    backend_version_token: str | None = None
    backend_change_id: int | None = Field(default=None, ge=1)

    @property
    def version(self) -> int:
        if not self.backend_version_token:
            return 0
        digits = "".join(ch for ch in self.backend_version_token if ch.isdigit())
        return int(digits) if digits else 0


class SyncApplePushRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    cursor: str | None = None
    tasks: list[SyncApplePushTask] = Field(default_factory=list)
    limit: int = Field(default=100, ge=1, le=500)


class SyncAppleAckItem(BaseModel):
    task_id: UUID
    remote_id: str | None = None
    version: int
    delivery_id: UUID | None = None
    delivery_seq: int | None = Field(default=None, ge=1)
    change_id: int | None = Field(default=None, ge=1)
    status: Literal["success", "failed", "conflict", "acked", "applied"] = "success"
    apple_modified_at: datetime | None = None
    apple_list_id: str | None = None
    apple_calendar_id: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    retryable: bool = False


class SyncAppleAckRequest(BaseModel):
    bridge_id: str = Field(min_length=1, max_length=255)
    acks: list[SyncAppleAckItem] = Field(default_factory=list)


class SyncBridgeDeliverySummary(BaseModel):
    task_id: str
    delivery_id: UUID | None = None
    delivery_seq: int | None = None
    change_id: int
    task_version: int
    operation: str
    status: str
    attempt_count: int
    retryable: bool
    remote_id: str | None = None
    last_error_code: str | None = None
    last_error_message: str | None = None
    first_pushed_at: datetime | None = None
    last_pushed_at: datetime | None = None
    acked_at: datetime | None = None
    failed_at: datetime | None = None

    @field_serializer("first_pushed_at", "last_pushed_at", "acked_at", "failed_at", when_used="json")
    def serialize_datetimes(self, value: datetime | None) -> str | None:
        return isoformat_z(value)


class SyncBridgeStateRead(BaseModel):
    bridge_id: str
    backend_cursor: str | None = None
    last_pull_cursor: str | None = None
    last_push_cursor: str | None = None
    last_acked_change_id: int | None = None
    last_failed_change_id: int | None = None
    last_seen_change_id: int | None = None
    next_delivery_seq: int | None = None
    last_acked_delivery_seq: int | None = None
    last_failed_delivery_seq: int | None = None
    last_seen_delivery_seq: int | None = None
    pending_delivery_count: int = 0
    last_pull_started_at: datetime | None = None
    last_pull_succeeded_at: datetime | None = None
    last_push_started_at: datetime | None = None
    last_push_succeeded_at: datetime | None = None
    last_ack_started_at: datetime | None = None
    last_ack_succeeded_at: datetime | None = None
    last_error_code: str | None = None
    last_error_message: str | None = None
    metadata: dict | None = None
    recent_deliveries: list[SyncBridgeDeliverySummary] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime

    @field_serializer(
        "last_pull_started_at",
        "last_pull_succeeded_at",
        "last_push_started_at",
        "last_push_succeeded_at",
        "last_ack_started_at",
        "last_ack_succeeded_at",
        "created_at",
        "updated_at",
        when_used="json",
    )
    def serialize_datetimes(self, value: datetime | None) -> str | None:
        return isoformat_z(value)
