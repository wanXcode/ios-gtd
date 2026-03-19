from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session, selectinload

from app.models.enums import TaskBucket, TaskStatus
from app.models.operation_log import OperationLog
from app.models.task import Task


@dataclass
class CaptureParseResult:
    title: str
    due_at: datetime | None
    time_expression: str | None
    confidence: float
    bucket: str = TaskBucket.INBOX.value
    status: str = TaskStatus.ACTIVE.value


class AssistantService:
    def __init__(self, db: Session):
        self.db = db

    def capture_task(
        self,
        *,
        text: str,
        source: str | None,
        source_ref: str | None,
        actor: str,
        timezone_name: str = "UTC",
        dry_run: bool = False,
    ) -> tuple[CaptureParseResult, Task | None]:
        parsed = parse_capture_input(text, timezone_name=timezone_name)
        if dry_run:
            return parsed, None

        task = Task(
            title=parsed.title,
            note=text.strip(),
            bucket=parsed.bucket,
            status=parsed.status,
            due_at=parsed.due_at,
            source=source,
            source_ref=source_ref,
            last_modified_by=actor,
        )
        self.db.add(task)
        self.db.flush()
        self.db.refresh(task)
        self.db.add(
            OperationLog(
                task_id=task.id,
                operation_type="assistant_capture",
                actor=actor,
                source="assistant",
                payload={
                    "input": text,
                    "parsed": serialize_parsed_capture(parsed),
                },
            )
        )
        self.db.commit()
        self.db.refresh(task)
        return parsed, task

    def list_today(self, *, timezone_name: str = "UTC", include_overdue: bool = True, limit: int = 50) -> list[Task]:
        tz = ZoneInfo(timezone_name)
        now_local = datetime.now(tz)
        today_start_local = datetime.combine(now_local.date(), time.min, tzinfo=tz)
        tomorrow_start_local = today_start_local + timedelta(days=1)

        today_start_utc = today_start_local.astimezone(timezone.utc)
        tomorrow_start_utc = tomorrow_start_local.astimezone(timezone.utc)

        stmt = (
            select(Task)
            .options(selectinload(Task.project), selectinload(Task.tags))
            .where(
                Task.deleted_at.is_(None),
                Task.status == TaskStatus.ACTIVE.value,
                Task.bucket != TaskBucket.SOMEDAY.value,
                Task.due_at.is_not(None),
            )
        )

        if include_overdue:
            stmt = stmt.where(Task.due_at < tomorrow_start_utc)
        else:
            stmt = stmt.where(and_(Task.due_at >= today_start_utc, Task.due_at < tomorrow_start_utc))

        stmt = stmt.order_by(Task.due_at.asc(), Task.priority.desc().nullslast(), Task.created_at.asc()).limit(limit)
        return list(self.db.scalars(stmt).unique().all())

    def list_waiting(self, *, limit: int = 100) -> list[Task]:
        stmt = (
            select(Task)
            .options(selectinload(Task.project), selectinload(Task.tags))
            .where(
                Task.deleted_at.is_(None),
                Task.status == TaskStatus.ACTIVE.value,
                Task.bucket == TaskBucket.WAITING.value,
            )
            .order_by(Task.updated_at.desc())
            .limit(limit)
        )
        return list(self.db.scalars(stmt).unique().all())


def serialize_parsed_capture(parsed: CaptureParseResult) -> dict:
    return {
        "title": parsed.title,
        "due_at": parsed.due_at.isoformat() if parsed.due_at else None,
        "time_expression": parsed.time_expression,
        "confidence": parsed.confidence,
        "bucket": parsed.bucket,
        "status": parsed.status,
    }


def parse_capture_input(text: str, *, timezone_name: str = "UTC") -> CaptureParseResult:
    raw = text.strip()
    if not raw:
        return CaptureParseResult(title="Untitled task", due_at=None, time_expression=None, confidence=0.2)

    lowered = raw.lower()
    tz = ZoneInfo(timezone_name)
    now = datetime.now(tz)

    time_expression: str | None = None
    due_at: datetime | None = None
    confidence = 0.45
    title = raw

    if "明天" in raw:
        target_date = now.date() + timedelta(days=1)
        due_at = _end_of_day(target_date, tz)
        time_expression = "明天"
        title = title.replace("明天", "").strip(" ，,。") or raw
        confidence = 0.76
    elif "今天" in raw:
        target_date = now.date()
        due_at = _end_of_day(target_date, tz)
        time_expression = "今天"
        title = title.replace("今天", "").strip(" ，,。") or raw
        confidence = 0.72
    elif "下周" in raw:
        next_week_date = now.date() + timedelta(days=7)
        due_at = _end_of_day(next_week_date, tz)
        time_expression = "下周"
        title = title.replace("下周前", "").replace("下周", "").strip(" 前截止于在前 ，,。") or raw
        confidence = 0.7

    prefix_candidates = [
        "提醒我",
        "记得",
        "需要",
        "待办",
        "todo:",
        "todo：",
    ]
    for prefix in prefix_candidates:
        if title.startswith(prefix):
            title = title[len(prefix) :].strip()
            break

    if not title:
        title = raw

    return CaptureParseResult(title=title, due_at=due_at, time_expression=time_expression, confidence=confidence)


def _end_of_day(target_date: date, tz: ZoneInfo) -> datetime:
    return datetime.combine(target_date, time(hour=18, minute=0), tzinfo=tz).astimezone(timezone.utc)
