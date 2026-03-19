from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.assistant import (
    AssistantCaptureParsed,
    AssistantCaptureRequest,
    AssistantCaptureResponse,
    AssistantTodayResponse,
    AssistantWaitingResponse,
)
from app.services.assistant import AssistantService, serialize_parsed_capture

router = APIRouter()


@router.post("/capture", response_model=AssistantCaptureResponse)
def capture(payload: AssistantCaptureRequest, db: Session = Depends(get_db)) -> AssistantCaptureResponse:
    service = AssistantService(db)
    parsed, task = service.capture_task(
        text=payload.input,
        source=payload.context.source,
        source_ref=payload.context.source_ref,
        actor=payload.context.actor,
        timezone_name=payload.context.timezone,
        dry_run=payload.dry_run,
    )
    return AssistantCaptureResponse(
        task=task,
        parsed=AssistantCaptureParsed(**serialize_parsed_capture(parsed)),
        dry_run=payload.dry_run,
    )


@router.get("/views/today", response_model=AssistantTodayResponse)
def view_today(
    timezone: str = Query(default="UTC"),
    include_overdue: bool = Query(default=True),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
) -> AssistantTodayResponse:
    service = AssistantService(db)
    items = service.list_today(timezone_name=timezone, include_overdue=include_overdue, limit=limit)
    return AssistantTodayResponse(timezone=timezone, include_overdue=include_overdue, items=items)


@router.get("/views/waiting", response_model=AssistantWaitingResponse)
def view_waiting(
    limit: int = Query(default=100, ge=1, le=200),
    db: Session = Depends(get_db),
) -> AssistantWaitingResponse:
    service = AssistantService(db)
    items = service.list_waiting(limit=limit)
    return AssistantWaitingResponse(items=items)
