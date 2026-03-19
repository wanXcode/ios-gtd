from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.apple_mapping import AppleReminderMapping
from app.models.enums import SyncState, TaskBucket, TaskStatus
from app.models.sync_run import SyncRun
from app.models.task import Task
from app.schemas.sync import (
    SyncAppleAckRequest,
    SyncApplePullChange,
    SyncApplePullRequest,
    SyncApplePushRequest,
)

router = APIRouter()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _normalize_dt(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _task_operation(task: Task) -> str:
    if task.deleted_at is not None or task.status == TaskStatus.DELETED.value:
        return "delete"
    if task.status == TaskStatus.COMPLETED.value:
        return "complete"
    return "upsert"


def _mapping_operation(mapping: AppleReminderMapping | None, task: Task) -> str:
    if mapping and mapping.pending_operation:
        return mapping.pending_operation
    return _task_operation(task)


def _serialize_push_item(task: Task, mapping: AppleReminderMapping | None) -> dict:
    operation = _mapping_operation(mapping, task)
    return {
        "task_id": str(task.id),
        "version": task.version,
        "change_id": task.sync_change_id,
        "operation": operation,
        "mapping": {
            "apple_reminder_id": mapping.apple_reminder_id if mapping else None,
            "apple_list_id": mapping.apple_list_id if mapping else None,
            "apple_calendar_id": mapping.apple_calendar_id if mapping else None,
            "sync_state": mapping.sync_state if mapping else None,
        },
        "task": {
            "title": task.title,
            "note": task.note,
            "status": task.status,
            "bucket": task.bucket,
            "priority": task.priority,
            "due_at": task.due_at.isoformat() if task.due_at else None,
            "remind_at": task.remind_at.isoformat() if task.remind_at else None,
            "completed_at": task.completed_at.isoformat() if task.completed_at else None,
            "deleted_at": task.deleted_at.isoformat() if task.deleted_at else None,
            "updated_at": task.updated_at.isoformat() if task.updated_at else None,
            "is_all_day_due": task.is_all_day_due,
            "source": task.source,
            "source_ref": task.source_ref,
        },
    }


def _apply_remote_upsert(db: Session, change: SyncApplePullChange) -> tuple[str, str, Task | None]:
    mapping = db.scalar(
        select(AppleReminderMapping).where(AppleReminderMapping.apple_reminder_id == change.apple_reminder_id)
    )
    task = db.scalar(select(Task).where(Task.id == mapping.task_id)) if mapping else None

    if mapping and task:
        remote_modified_at = _normalize_dt(change.apple_modified_at)
        local_updated_at = _normalize_dt(task.updated_at)
        if task.sync_pending and remote_modified_at and mapping.last_seen_apple_modified_at and local_updated_at:
            if remote_modified_at > mapping.last_seen_apple_modified_at and local_updated_at > mapping.updated_at:
                mapping.sync_state = SyncState.CONFLICT.value
                mapping.last_ack_status = "conflict"
                mapping.last_error_code = "task_modified_after_last_sync"
                mapping.last_error_message = "Local task changed after last sync and before remote update was applied"
                db.add(mapping)
                return "conflict", "task_modified_after_last_sync", task

    if change.change_type == "delete":
        if not mapping or not task:
            return "ignored", "mapping_not_found", None
        task.deleted_at = _normalize_dt(change.apple_modified_at) or _now()
        task.status = TaskStatus.DELETED.value
        task.completed_at = None
        task.last_modified_by = "apple_sync"
        task.version += 1
        task.sync_pending = False
        task.sync_last_pushed_at = _now()
        mapping.sync_state = SyncState.DELETED.value
        mapping.pending_operation = None
        mapping.last_ack_status = "success"
        mapping.is_deleted_on_apple = True
        mapping.last_seen_apple_modified_at = _normalize_dt(change.apple_modified_at)
        mapping.bridge_updated_at = _now()
        db.add(task)
        db.add(mapping)
        return "applied", "deleted", task

    if change.payload is None:
        raise HTTPException(status_code=422, detail="payload is required for upsert changes")

    if not task:
        task = Task(
            title=change.payload.title,
            note=change.payload.note,
            status=TaskStatus.COMPLETED.value if change.payload.is_completed else TaskStatus.ACTIVE.value,
            bucket=TaskBucket.DONE.value if change.payload.is_completed else TaskBucket.INBOX.value,
            priority=change.payload.priority,
            due_at=_normalize_dt(change.payload.due_at),
            remind_at=_normalize_dt(change.payload.remind_at),
            completed_at=_normalize_dt(change.apple_modified_at) if change.payload.is_completed else None,
            source="apple_sync",
            source_ref=change.apple_reminder_id,
            last_modified_by="apple_sync",
            is_all_day_due=change.payload.is_all_day_due,
            sync_pending=False,
        )
        db.add(task)
        db.flush()
        mapping = AppleReminderMapping(
            task_id=task.id,
            apple_reminder_id=change.apple_reminder_id,
            apple_list_id=change.apple_list_id,
            apple_calendar_id=change.apple_calendar_id,
            last_synced_task_version=task.version,
            last_seen_apple_modified_at=_normalize_dt(change.apple_modified_at),
            sync_state=SyncState.ACTIVE.value,
            pending_operation=None,
            bridge_updated_at=_now(),
            last_ack_status="success",
        )
        db.add(mapping)
        return "applied", "created", task

    task.title = change.payload.title
    task.note = change.payload.note
    task.priority = change.payload.priority
    task.due_at = _normalize_dt(change.payload.due_at)
    task.remind_at = _normalize_dt(change.payload.remind_at)
    task.is_all_day_due = change.payload.is_all_day_due
    task.source = "apple_sync"
    task.source_ref = change.apple_reminder_id
    task.last_modified_by = "apple_sync"
    task.deleted_at = None
    task.sync_pending = False
    task.sync_last_pushed_at = _now()
    if change.payload.is_completed:
        task.status = TaskStatus.COMPLETED.value
        task.bucket = TaskBucket.DONE.value
        task.completed_at = _normalize_dt(change.apple_modified_at) or _now()
    else:
        task.status = TaskStatus.ACTIVE.value
        if task.bucket == TaskBucket.DONE.value:
            task.bucket = TaskBucket.INBOX.value
        task.completed_at = None
    task.version += 1

    mapping.apple_list_id = change.apple_list_id
    mapping.apple_calendar_id = change.apple_calendar_id
    mapping.last_seen_apple_modified_at = _normalize_dt(change.apple_modified_at)
    mapping.last_synced_task_version = task.version
    mapping.sync_state = SyncState.ACTIVE.value
    mapping.pending_operation = None
    mapping.bridge_updated_at = _now()
    mapping.last_ack_status = "success"
    mapping.last_error_code = None
    mapping.last_error_message = None
    mapping.is_deleted_on_apple = False
    db.add(task)
    db.add(mapping)
    return "applied", "updated", task


@router.post("/apple/pull")
def apple_pull(payload: SyncApplePullRequest, db: Session = Depends(get_db)) -> dict:
    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="running",
        started_at=_now(),
        stats={"mode": "pull", "limit": payload.limit, "cursor": payload.cursor},
    )
    db.add(run)

    accepted = 0
    applied = 0
    conflicts = 0
    results = []
    next_cursor = payload.cursor

    for change in payload.changes[: payload.limit] if hasattr(payload, "changes") else []:
        accepted += 1
        result, reason, task = _apply_remote_upsert(db, change)
        if result == "applied":
            applied += 1
        elif result == "conflict":
            conflicts += 1
        results.append(
            {
                "apple_reminder_id": change.apple_reminder_id,
                "task_id": str(task.id) if task else None,
                "result": result,
                "reason": reason,
            }
        )
        next_cursor = change.apple_modified_at.isoformat() if change.apple_modified_at else next_cursor

    run.status = "success"
    run.finished_at = _now()
    run.stats = {
        "mode": "pull",
        "accepted": accepted,
        "applied": applied,
        "conflicts": conflicts,
        "cursor": payload.cursor,
        "next_cursor": next_cursor,
    }
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "pull",
        "bridge_id": payload.bridge_id,
        "cursor": payload.cursor,
        "next_cursor": next_cursor,
        "accepted": accepted,
        "applied": applied,
        "conflicts": conflicts,
        "results": results,
    }


@router.post("/apple/push")
def apple_push(payload: SyncApplePushRequest, db: Session = Depends(get_db)) -> dict:
    stmt = (
        select(Task, AppleReminderMapping)
        .outerjoin(AppleReminderMapping, AppleReminderMapping.task_id == Task.id)
        .where(or_(Task.sync_pending.is_(True), AppleReminderMapping.pending_operation.is_not(None)))
        .order_by(Task.sync_change_id.asc(), Task.updated_at.asc())
        .limit(payload.limit)
    )
    rows = list(db.execute(stmt).all())

    requested_versions = {item.task_id: item.version for item in payload.tasks}
    items = []
    next_cursor = payload.cursor
    returned = 0
    for task, mapping in rows:
        requested_version = requested_versions.get(task.id)
        if requested_version is not None and requested_version >= task.version:
            continue
        items.append(_serialize_push_item(task, mapping))
        returned += 1
        next_cursor = str(task.sync_change_id)
        task.sync_last_pushed_at = _now()
        if mapping:
            mapping.pending_operation = _mapping_operation(mapping, task)
            mapping.last_push_change_id = task.sync_change_id
            db.add(mapping)
        db.add(task)

    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=_now(),
        finished_at=_now(),
        stats={
            "mode": "push",
            "requested": len(payload.tasks),
            "returned": returned,
            "cursor": payload.cursor,
            "next_cursor": next_cursor,
        },
    )
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "push",
        "bridge_id": payload.bridge_id,
        "cursor": payload.cursor,
        "next_cursor": next_cursor,
        "items": items,
    }


@router.post("/apple/ack")
def apple_ack(payload: SyncAppleAckRequest, db: Session = Depends(get_db)) -> dict:
    acked = []
    success = 0
    failed = 0
    conflict = 0

    for item in payload.acks:
        task = db.scalar(select(Task).where(Task.id == item.task_id))
        if not task:
            raise HTTPException(status_code=404, detail=f"Task not found: {item.task_id}")

        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == item.task_id))
        if not mapping and item.remote_id:
            mapping = AppleReminderMapping(
                task_id=item.task_id,
                apple_reminder_id=item.remote_id,
                last_synced_task_version=item.version,
                last_seen_apple_modified_at=_normalize_dt(item.apple_modified_at),
                sync_state=SyncState.ACTIVE.value,
            )
            db.add(mapping)
            db.flush()
        elif not mapping:
            raise HTTPException(status_code=404, detail=f"Mapping not found for task: {item.task_id}")

        if item.remote_id:
            mapping.apple_reminder_id = item.remote_id
        mapping.apple_list_id = item.apple_list_id or mapping.apple_list_id
        mapping.apple_calendar_id = item.apple_calendar_id or mapping.apple_calendar_id
        mapping.last_seen_apple_modified_at = _normalize_dt(item.apple_modified_at) or mapping.last_seen_apple_modified_at
        mapping.bridge_updated_at = _now()
        mapping.last_ack_status = item.status
        mapping.last_error_code = item.error_code
        mapping.last_error_message = item.error_message

        if item.status in {"success", "acked"}:
            success += 1
            task.sync_pending = False
            task.sync_last_pushed_at = _now()
            mapping.last_synced_task_version = task.version
            mapping.last_push_change_id = task.sync_change_id
            mapping.pending_operation = None
            mapping.sync_state = SyncState.DELETED.value if _task_operation(task) == "delete" else SyncState.ACTIVE.value
            mapping.is_deleted_on_apple = _task_operation(task) == "delete"
        elif item.status == "conflict":
            conflict += 1
            mapping.sync_state = SyncState.CONFLICT.value
        else:
            failed += 1
            task.sync_pending = True
            mapping.pending_operation = _task_operation(task)

        db.add(task)
        db.add(mapping)
        acked.append(
            {
                "task_id": str(item.task_id),
                "remote_id": mapping.apple_reminder_id,
                "version": item.version,
                "change_id": task.sync_change_id,
                "status": item.status,
            }
        )

    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=_now(),
        finished_at=_now(),
        stats={"mode": "ack", "acked": len(acked), "success": success, "failed": failed, "conflict": conflict},
    )
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "ack",
        "bridge_id": payload.bridge_id,
        "acked": acked,
        "success": success,
        "failed": failed,
        "conflict": conflict,
    }
