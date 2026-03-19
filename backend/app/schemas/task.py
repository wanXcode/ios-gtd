from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from app.models.enums import TaskBucket, TaskStatus
from app.schemas.common import ORMModel
from app.schemas.project import ProjectRead
from app.schemas.tag import TagRead


class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=255)
    note: str | None = None
    status: str = TaskStatus.ACTIVE.value
    bucket: str = TaskBucket.INBOX.value
    priority: int | None = Field(default=None, ge=1, le=9)
    due_at: datetime | None = None
    remind_at: datetime | None = None
    source: str | None = None
    source_ref: str | None = None
    project_id: UUID | None = None
    tag_ids: list[UUID] = Field(default_factory=list)
    last_modified_by: str = "api"
    is_all_day_due: bool = False


class TaskUpdate(BaseModel):
    title: str | None = Field(default=None, min_length=1, max_length=255)
    note: str | None = None
    status: str | None = None
    bucket: str | None = None
    priority: int | None = Field(default=None, ge=1, le=9)
    due_at: datetime | None = None
    remind_at: datetime | None = None
    completed_at: datetime | None = None
    deleted_at: datetime | None = None
    source: str | None = None
    source_ref: str | None = None
    project_id: UUID | None = None
    tag_ids: list[UUID] | None = None
    last_modified_by: str | None = None
    is_all_day_due: bool | None = None


class TaskBatchUpdateItem(BaseModel):
    id: UUID
    patch: TaskUpdate


class TaskBatchUpdateRequest(BaseModel):
    updates: list[TaskBatchUpdateItem] = Field(min_length=1)


class TaskRead(ORMModel):
    id: UUID
    title: str
    note: str | None = None
    status: str
    bucket: str
    priority: int | None = None
    due_at: datetime | None = None
    remind_at: datetime | None = None
    completed_at: datetime | None = None
    deleted_at: datetime | None = None
    source: str | None = None
    source_ref: str | None = None
    project_id: UUID | None = None
    is_all_day_due: bool = False
    sync_change_id: int
    sync_pending: bool
    sync_last_pushed_at: datetime | None = None
    created_at: datetime
    updated_at: datetime
    last_modified_by: str
    version: int
    project: ProjectRead | None = None
    tags: list[TagRead] = []
