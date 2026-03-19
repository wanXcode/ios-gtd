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
    remind_at: datetime | None
    time_expression: str | None
    confidence: float
    needs_confirmation: bool
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
            remind_at=draft.remind_at,
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
        "remind_at": draft.remind_at.isoformat() if draft.remind_at else None,
        "time_expression": draft.time_expression,
        "confidence": draft.confidence,
        "needs_confirmation": draft.needs_confirmation,
        "project_name": draft.project_name,
        "project_description": draft.project_description,
    }


def parse_capture_input(text: str, *, timezone_name: str = "UTC") -> CaptureDraft:
    raw = text.strip()
    if not raw:
        return CaptureDraft(
            intent="create_task",
            title="Untitled task",
            summary="Untitled task",
            note=None,
            due_at=None,
            remind_at=None,
            time_expression=None,
            confidence=0.2,
            bucket=TaskBucket.INBOX.value,
            status=TaskStatus.ACTIVE.value,
            needs_confirmation=True,
        )

    tz = ZoneInfo(timezone_name)
    now = datetime.now(tz)

    initial_intent = _detect_intent(raw)
    temporal = _extract_temporal_info(raw, tz=tz, now=now)
    stripped_text = _strip_command_prefix(temporal["summary"])
    normalized = _cleanup_summary(stripped_text) or raw

    intent = initial_intent
    if intent == "capture_inbox" and (temporal["due_at"] is not None or temporal["time_expression"]):
        intent = "create_task"

    if intent == "create_project":
        project_name = _extract_project_name(normalized)
        return CaptureDraft(
            intent=intent,
            title=project_name,
            summary=project_name,
            note=raw,
            bucket=TaskBucket.PROJECT.value,
            status=TaskStatus.ACTIVE.value,
            due_at=None,
            remind_at=None,
            time_expression=temporal["time_expression"],
            confidence=0.83 if project_name != raw else 0.68,
            needs_confirmation=project_name == raw,
            project_name=project_name,
            project_description=None,
        )

    bucket = _infer_bucket(raw, normalized)
    if intent == "capture_inbox" and bucket != TaskBucket.INBOX.value:
        intent = "create_task"

    confidence = 0.58
    if temporal["time_expression"]:
        confidence += 0.14
    if temporal["explicit_time"]:
        confidence += 0.08
    if bucket != TaskBucket.INBOX.value:
        confidence += 0.05
    if normalized != raw:
        confidence += 0.05

    needs_confirmation = False
    if normalized == "Untitled task":
        needs_confirmation = True
    if temporal["time_expression"] == "下周" and not temporal["explicit_time"]:
        needs_confirmation = True
    if any(keyword in raw for keyword in ["找时间", "有空", "回头", "尽快"]) and temporal["due_at"] is None:
        needs_confirmation = True

    confidence = min(confidence, 0.96)
    if needs_confirmation:
        confidence = min(confidence, 0.78)

    return CaptureDraft(
        intent="create_task",
        title=normalized,
        summary=normalized,
        note=raw,
        bucket=bucket,
        status=TaskStatus.ACTIVE.value,
        due_at=temporal["due_at"],
        remind_at=temporal["remind_at"],
        time_expression=temporal["time_expression"],
        confidence=confidence,
        needs_confirmation=needs_confirmation,
    )


def _detect_intent(text: str) -> AssistantIntent:
    lowered = text.lower().strip()
    if text.startswith(("建项目", "创建项目", "新建项目", "项目：", "项目:")) or lowered.startswith(("project:", "create project ")):
        return "create_project"
    if text.startswith(("提醒我", "帮我记", "记得", "待办", "todo:", "todo：", "需要")):
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


def _infer_bucket(raw: str, normalized: str) -> str:
    combined = f"{raw} {normalized}"
    if any(keyword in combined for keyword in ["以后再说", "晚点再说", "回头再说", "有空再说"]):
        return TaskBucket.SOMEDAY.value
    if any(keyword in combined for keyword in ["项目", "project", "方案", "计划", "里程碑", "拆分", "需求"]):
        return TaskBucket.NEXT.value
    return TaskBucket.INBOX.value


def _extract_temporal_info(raw: str, *, tz: ZoneInfo, now: datetime) -> dict:
    text = raw
    explicit_time = False
    due_at: datetime | None = None
    remind_at: datetime | None = None
    time_expression: str | None = None

    time_match = re.search(r"(?<!\d)(\d{1,2})(?:[:点时](\d{1,2}))?(?:点|时)?\s*(半)?", text)
    hour: int | None = None
    minute: int | None = None
    if time_match:
        hour = int(time_match.group(1))
        minute = int(time_match.group(2) or 0)
        if time_match.group(3):
            minute = 30
        explicit_time = True

    if "明晚" in text:
        time_expression = "明晚"
        target_date = now.date() + timedelta(days=1)
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=20), tz)
        remind_at = due_at - timedelta(hours=2)
        text = text.replace("明晚", "", 1)
    elif "今晚" in text:
        time_expression = "今晚"
        target_date = now.date()
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=20), tz)
        remind_at = due_at - timedelta(hours=2)
        text = text.replace("今晚", "", 1)
    elif "明天" in text:
        time_expression = "明天"
        target_date = now.date() + timedelta(days=1)
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=18), tz)
        if explicit_time:
            remind_at = due_at - timedelta(hours=1)
        text = text.replace("明天", "", 1)
    elif "后天" in text:
        time_expression = "后天"
        target_date = now.date() + timedelta(days=2)
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=18), tz)
        if explicit_time:
            remind_at = due_at - timedelta(hours=1)
        text = text.replace("后天", "", 1)
    elif "今天" in text:
        time_expression = "今天"
        target_date = now.date()
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=18), tz)
        if explicit_time:
            remind_at = due_at - timedelta(hours=1)
        text = text.replace("今天", "", 1)
    elif "下周" in text:
        time_expression = "下周"
        days_until_next_monday = 7 - now.weekday()
        if days_until_next_monday <= 0:
            days_until_next_monday += 7
        target_date = now.date() + timedelta(days=days_until_next_monday)
        due_at = _combine_date_time(target_date, _normalize_clock(hour, minute, fallback_hour=18), tz)
        if explicit_time:
            remind_at = due_at - timedelta(days=1)
        text = text.replace("下周前", "", 1).replace("下周", "", 1)

    if time_match and time_expression:
        refreshed_match = re.search(r"(?<!\d)(\d{1,2})(?:[:点时](\d{1,2}))?(?:点|时)?\s*(半)?", text)
        if refreshed_match:
            text = text[: refreshed_match.start()] + " " + text[refreshed_match.end() :]

    return {
        "summary": text,
        "due_at": due_at,
        "remind_at": remind_at,
        "time_expression": time_expression,
        "explicit_time": explicit_time,
    }


def _cleanup_summary(text: str) -> str:
    value = text
    for token in ["以后再说", "晚点再说", "回头再说", "有空再说", "前", "截止", "一下"]:
        value = value.replace(token, " ")
    value = re.sub(r"\s+", " ", value)
    value = value.strip(" ，,。；;：:!?！？")
    return value.strip() or "Untitled task"


def _normalize_clock(hour: int | None, minute: int | None, *, fallback_hour: int) -> tuple[int, int]:
    if hour is None:
        return fallback_hour, 0
    normalized_hour = hour
    if fallback_hour >= 18 and 1 <= hour < 12:
        normalized_hour = hour + 12
    return max(0, min(normalized_hour, 23)), max(0, min(minute or 0, 59))


def _combine_date_time(target_date: date, clock_time: tuple[int, int], tz: ZoneInfo) -> datetime:
    hour, minute = clock_time
    return datetime.combine(target_date, time(hour=hour, minute=minute), tzinfo=tz).astimezone(timezone.utc)
