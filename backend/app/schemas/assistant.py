from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

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

    @model_validator(mode="before")
    @classmethod
    def normalize_legacy_contract(cls, data: Any) -> Any:
        if not isinstance(data, dict):
            return data

        normalized = dict(data)
        if "input" not in normalized and "text" in normalized:
            normalized["input"] = normalized["text"]

        if "apply" not in normalized and "dry_run" in normalized:
            normalized["apply"] = not bool(normalized["dry_run"])

        return normalized


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
    questions: list[str] = Field(default_factory=list)
    error_code: str | None = None
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
    questions: list[str] = Field(default_factory=list)
    error_code: str | None = None


class AssistantTodayResponse(BaseModel):
    timezone: str
    include_overdue: bool
    items: list[TaskRead]


class AssistantWaitingResponse(BaseModel):
    items: list[TaskRead]
