from datetime import datetime

from pydantic import BaseModel, Field

from app.schemas.task import TaskRead


class AssistantContext(BaseModel):
    timezone: str = "UTC"
    source: str | None = None
    source_ref: str | None = None
    actor: str = "assistant"


class AssistantCaptureRequest(BaseModel):
    input: str = Field(min_length=1, max_length=2000)
    context: AssistantContext = Field(default_factory=AssistantContext)
    dry_run: bool = False


class AssistantCaptureParsed(BaseModel):
    title: str
    due_at: datetime | None = None
    time_expression: str | None = None
    confidence: float
    bucket: str
    status: str


class AssistantCaptureResponse(BaseModel):
    task: TaskRead | None = None
    parsed: AssistantCaptureParsed
    dry_run: bool


class AssistantTodayResponse(BaseModel):
    timezone: str
    include_overdue: bool
    items: list[TaskRead]


class AssistantWaitingResponse(BaseModel):
    items: list[TaskRead]
