from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from typing import Literal
from zoneinfo import ZoneInfo

from sqlalchemy import and_, select
from sqlalchemy.orm import Session, selectinload

from app.models.enums import ProjectStatus, TaskBucket, TaskStatus
from app.models.operation_log import OperationLog
from app.models.project import Project
from app.models.task import Task

AssistantIntent = Literal["create_task", "capture_inbox", "create_project"]


@dataclass
class CaptureDraft:
    intent: AssistantIntent
    title: str
    summary: str
    note: str | None
    bucket: str
    status: str
    due_at: datetime | None
    time_expression: str | None
    confidence: float
    project_name: str | None = None
    project_description: str | None = None


class AssistantService:
    def __init__(self, db: Session):
        self.db = db

    def capture(
        self,
        *,
        text: str,
        source: str | None,
        source_ref: str | None,
        actor: str,
        timezone_name: str = "UTC",
        apply: bool = False,
    ) -> tuple[CaptureDraft, Task | Project | None]:
        draft = parse_capture_input(text, timezone_name=timezone_name)
        if not apply:
            return draft, None

        created = self._apply_draft(
            draft=draft,
            raw_input=text,
            source=source,
            source_ref=source_ref,
            actor=actor,
        )
        return draft, created

    def _apply_draft(
        self,
        *,
        draft: CaptureDraft,
        raw_input: str,
        source: str | None,
        source_ref: str | None,
        actor: str,
    ) -> Task | Project:
        if draft.intent == "create_project":
            project = Project(
                name=draft.project_name or draft.title,
                description=draft.project_description or draft.note,
                status=ProjectStatus.ACTIVE.value,
            )
            self.db.add(project)
            self.db.flush()
            self.db.refresh(project)
            self.db.add(
                OperationLog(
                    task_id=None,
                    operation_type="assistant_capture_project",
                    actor=actor,
                    source="assistant",
                    payload={
                        "input": raw_input,
                        "draft": serialize_capture_draft(draft),
                        "project_id": str(project.id),
                        "source": source,
                        "source_ref": source_ref,
                    },
                )
            )
            self.db.commit()
            self.db.refresh(project)
            return project

        task = Task(
            title=draft.title,
            note=draft.note,
            bucket=draft.bucket,
            status=draft.status,
            due_at=draft.due_at,
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
                    "input": raw_input,
                    "draft": serialize_capture_draft(draft),
                },
            )
        )
        self.db.commit()
        self.db.refresh(task)
        return task

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


def serialize_capture_draft(draft: CaptureDraft) -> dict:
    return {
        "intent": draft.intent,
        "title": draft.title,
        "summary": draft.summary,
        "note": draft.note,
        "bucket": draft.bucket,
        "status": draft.status,
        "due_at": draft.due_at.isoformat() if draft.due_at else None,
        "time_expression": draft.time_expression,
        "confidence": draft.confidence,
        "project_name": draft.project_name,
        "project_description": draft.project_description,
    }


def parse_capture_input(text: str, *, timezone_name: str = "UTC") -> CaptureDraft:
    raw = text.strip()
    if not raw:
        return CaptureDraft(
            intent="capture_inbox",
            title="Untitled inbox item",
            summary="Untitled inbox item",
            note=None,
            due_at=None,
            time_expression=None,
            confidence=0.2,
            bucket=TaskBucket.INBOX.value,
            status=TaskStatus.ACTIVE.value,
        )

    tz = ZoneInfo(timezone_name)
    now = datetime.now(tz)
    intent_hint = _detect_intent(raw)
    due_at, time_expression, stripped_text = _extract_due_at(raw, tz=tz, now=now, parse_time=intent_hint == "create_task")
    intent = _detect_intent(stripped_text)
    normalized = _strip_command_prefix(stripped_text)
    normalized = normalized.strip(" ，,。；;:\n\t") or raw

    bucket = TaskBucket.INBOX.value
    status = TaskStatus.ACTIVE.value
    confidence = 0.58
    note = raw
    project_name: str | None = None
    project_description: str | None = None

    if intent == "create_project":
        project_name = _extract_project_name(normalized)
        summary = project_name
        confidence = 0.83 if project_name != raw else 0.68
        return CaptureDraft(
            intent=intent,
            title=project_name,
            summary=summary,
            note=note,
            bucket=TaskBucket.PROJECT.value,
            status=status,
            due_at=None,
            time_expression=time_expression,
            confidence=confidence,
            project_name=project_name,
            project_description=project_description,
        )

    if intent == "create_task":
        bucket = TaskBucket.NEXT.value if due_at else TaskBucket.INBOX.value
        confidence = 0.86 if due_at else 0.72
    else:
        bucket = TaskBucket.INBOX.value
        confidence = 0.74 if normalized != raw else 0.61

    title = normalized
    return CaptureDraft(
        intent=intent,
        title=title,
        summary=title,
        note=note,
        bucket=bucket,
        status=status,
        due_at=due_at,
        time_expression=time_expression,
        confidence=confidence,
        project_name=project_name,
        project_description=project_description,
    )


def _detect_intent(text: str) -> AssistantIntent:
    lowered = text.lower()
    if text.startswith(("建项目", "创建项目", "新建项目", "项目：", "项目:")) or lowered.startswith(("project:", "create project ")):
        return "create_project"
    if (
        text.startswith(("提醒我", "帮我记", "记得", "待办", "todo:", "todo：", "需要"))
        or "提醒我" in text
        or "帮我记" in text
    ):
        return "create_task"
    return "capture_inbox"


def _strip_command_prefix(text: str) -> str:
    prefixes = [
        "提醒我",
        "帮我记一个任务",
        "帮我记个任务",
        "帮我记",
        "记得",
        "需要",
        "待办",
        "todo:",
        "todo：",
        "建项目",
        "创建项目",
        "新建项目",
        "项目：",
        "项目:",
        "create project ",
        "project:",
    ]
    normalized = text.strip()
    lowered = normalized.lower()
    for prefix in prefixes:
        if prefix.isascii():
            if lowered.startswith(prefix):
                return normalized[len(prefix) :].strip()
        elif normalized.startswith(prefix):
            return normalized[len(prefix) :].strip()
    return normalized


def _extract_project_name(text: str) -> str:
    candidate = _strip_command_prefix(text)
    candidate = candidate.strip(" ：:，,。；;")
    return candidate or text.strip()


def _extract_due_at(raw: str, *, tz: ZoneInfo, now: datetime, parse_time: bool) -> tuple[datetime | None, str | None, str]:
    text = raw

    for marker, day_offset in (("明天", 1), ("今天", 0)):
        if marker in text and parse_time:
            due_time = _extract_clock_time(text)
            target_date = now.date() + timedelta(days=day_offset)
            due_at = _combine_date_time(target_date, due_time[1] if due_time else None, tz)
            text = text.replace(marker, "", 1)
            if due_time and due_time[1][1] == 0:
                text = re.sub(r"(上午|中午|下午|晚上|晚)?\s*\d{1,2}点(半)?", "", text, count=1)
            return due_at, marker if not due_time else f"{marker}{due_time[0]}", text.strip()

    if parse_time and ("下周前" in text or text.startswith("下周") or " 提醒我下周" in f" {text}"):
        target_date = now.date() + timedelta(days=7)
        expression = "下周前" if "下周前" in text else "下周"
        text = text.replace("下周前", "", 1).replace("下周", "", 1)
        return _end_of_day(target_date, tz), expression, text.strip()

    return None, None, text.strip()


def _extract_clock_time(text: str) -> tuple[str, tuple[int, int]] | None:
    match = re.search(r"(上午|中午|下午|晚上|晚)?\s*(\d{1,2})点(半)?", text)
    if not match:
        return None

    period = match.group(1) or ""
    hour = int(match.group(2))
    minute = 30 if match.group(3) else 0

    if period in {"下午", "晚上", "晚"} and hour < 12:
        hour += 12
    if period == "中午" and hour < 11:
        hour += 12

    return match.group(0), (hour, minute)


def _combine_date_time(target_date: date, clock_time: tuple[int, int] | None, tz: ZoneInfo) -> datetime:
    hour, minute = clock_time if clock_time else (18, 0)
    return datetime.combine(target_date, time(hour=hour, minute=minute), tzinfo=tz).astimezone(timezone.utc)


def _end_of_day(target_date: date, tz: ZoneInfo) -> datetime:
    return _combine_date_time(target_date, (18, 0), tz)
