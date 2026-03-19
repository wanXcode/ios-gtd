from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field

from app.schemas.project import ProjectRead
from app.schemas.task import TaskRead


AssistantIntent = Literal["create_task", "capture_inbox", "create_project"]


class AssistantContext(BaseModel):
    timezone: str = "UTC"
    source: str | None = None
    source_ref: str | None = None
    actor: str = "assistant"


class AssistantCaptureRequest(BaseModel):
    input: str = Field(min_length=1, max_length=2000)
    context: AssistantContext = Field(default_factory=AssistantContext)
    apply: bool = False


class AssistantCaptureDraft(BaseModel):
    intent: AssistantIntent
    title: str
    summary: str
    note: str | None = None
    bucket: str
    status: str
    due_at: datetime | None = None
    remind_at: datetime | None = None
    time_expression: str | None = None
    confidence: float
    needs_confirmation: bool
    project_name: str | None = None
    project_description: str | None = None


class AssistantCreatedEntity(BaseModel):
    entity_type: Literal["task", "project"]
    task: TaskRead | None = None
    project: ProjectRead | None = None
    task_id: UUID | None = None
    project_id: UUID | None = None


class AssistantCaptureResponse(BaseModel):
    draft: AssistantCaptureDraft
    applied: bool
    created: AssistantCreatedEntity | None = None


class AssistantTodayResponse(BaseModel):
    timezone: str
    include_overdue: bool
    items: list[TaskRead]


class AssistantWaitingResponse(BaseModel):
    items: list[TaskRead]
