from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.apple_mapping import AppleReminderMapping
from app.models.enums import SyncState, TaskBucket, TaskStatus
from app.models.sync_bridge_state import SyncBridgeState
from app.models.sync_delivery import SyncDelivery
from app.models.sync_run import SyncRun
from app.models.task import Task
from app.schemas.sync import (
    SyncAppleAckRequest,
    SyncApplePullChange,
    SyncApplePullRequest,
    SyncApplePushRequest,
    SyncBridgeDeliverySummary,
    SyncBridgeStateRead,
)
from app.utils_datetime import isoformat_z, normalize_utc

router = APIRouter()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _normalize_dt(value: datetime | None) -> datetime | None:
    return normalize_utc(value)


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
            "last_ack_status": mapping.last_ack_status if mapping else None,
            "last_error_code": mapping.last_error_code if mapping else None,
            "last_error_message": mapping.last_error_message if mapping else None,
            "last_push_change_id": mapping.last_push_change_id if mapping else None,
            "last_acked_change_id": mapping.last_acked_change_id if mapping else None,
            "last_delivery_status": mapping.last_delivery_status if mapping else None,
            "last_delivery_attempt_count": mapping.last_delivery_attempt_count if mapping else None,
            "last_failed_change_id": mapping.last_failed_change_id if mapping else None,
            "bridge_updated_at": isoformat_z(mapping.bridge_updated_at) if mapping else None,
        },
        "task": {
            "title": task.title,
            "note": task.note,
            "status": task.status,
            "bucket": task.bucket,
            "priority": task.priority,
            "due_at": isoformat_z(task.due_at),
            "remind_at": isoformat_z(task.remind_at),
            "completed_at": isoformat_z(task.completed_at),
            "deleted_at": isoformat_z(task.deleted_at),
            "updated_at": isoformat_z(task.updated_at),
            "is_all_day_due": task.is_all_day_due,
            "source": task.source,
            "source_ref": task.source_ref,
        },
    }


def _get_or_create_bridge_state(db: Session, bridge_id: str) -> SyncBridgeState:
    state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == bridge_id))
    if state:
        return state
    state = SyncBridgeState(bridge_id=bridge_id)
    db.add(state)
    db.flush()
    return state


def _get_or_create_delivery(
    db: Session,
    *,
    bridge_id: str,
    task_id: str,
    change_id: int,
    version: int,
    operation: str,
    remote_id: str | None = None,
) -> SyncDelivery:
    delivery = db.scalar(
        select(SyncDelivery).where(
            SyncDelivery.bridge_id == bridge_id,
            SyncDelivery.task_id == task_id,
            SyncDelivery.change_id == change_id,
        )
    )
    now = _now()
    if delivery:
        delivery.attempt_count += 1
        delivery.last_pushed_at = now
        delivery.status = "pending"
        delivery.failed_at = None
        delivery.acked_at = None
        delivery.task_version = version
        delivery.operation = operation
        delivery.remote_id = remote_id or delivery.remote_id
        db.add(delivery)
        return delivery

    delivery = SyncDelivery(
        bridge_id=bridge_id,
        task_id=task_id,
        change_id=change_id,
        task_version=version,
        operation=operation,
        status="pending",
        attempt_count=1,
        remote_id=remote_id,
        first_pushed_at=now,
        last_pushed_at=now,
    )
    db.add(delivery)
    db.flush()
    return delivery


def _pending_delivery_statuses() -> tuple[str, ...]:
    return ("pending", "retryable_failed", "failed", "conflict")


def _replayable_delivery_statuses() -> tuple[str, ...]:
    return ("pending", "retryable_failed", "failed", "conflict")


def _serialize_bridge_state(state: SyncBridgeState, db: Session) -> SyncBridgeStateRead:
    pending_delivery_count = db.scalar(
        select(func.count())
        .select_from(SyncDelivery)
        .where(
            SyncDelivery.bridge_id == state.bridge_id,
            SyncDelivery.status.in_(_pending_delivery_statuses()),
        )
    )
    deliveries = list(
        db.scalars(
            select(SyncDelivery)
            .where(SyncDelivery.bridge_id == state.bridge_id)
            .order_by(SyncDelivery.last_pushed_at.desc(), SyncDelivery.created_at.desc())
            .limit(10)
        ).all()
    )
    return SyncBridgeStateRead(
        bridge_id=state.bridge_id,
        backend_cursor=state.backend_cursor,
        last_pull_cursor=state.last_pull_cursor,
        last_push_cursor=state.last_push_cursor,
        last_acked_change_id=state.last_acked_change_id,
        last_failed_change_id=state.last_failed_change_id,
        last_seen_change_id=state.last_seen_change_id,
        pending_delivery_count=pending_delivery_count or 0,
        last_pull_started_at=state.last_pull_started_at,
        last_pull_succeeded_at=state.last_pull_succeeded_at,
        last_push_started_at=state.last_push_started_at,
        last_push_succeeded_at=state.last_push_succeeded_at,
        last_ack_started_at=state.last_ack_started_at,
        last_ack_succeeded_at=state.last_ack_succeeded_at,
        last_error_code=state.last_error_code,
        last_error_message=state.last_error_message,
        metadata=state.metadata_json,
        recent_deliveries=[
            SyncBridgeDeliverySummary(
                task_id=delivery.task_id,
                change_id=delivery.change_id,
                task_version=delivery.task_version,
                operation=delivery.operation,
                status=delivery.status,
                attempt_count=delivery.attempt_count,
                retryable=delivery.retryable,
                remote_id=delivery.remote_id,
                last_error_code=delivery.last_error_code,
                last_error_message=delivery.last_error_message,
                first_pushed_at=delivery.first_pushed_at,
                last_pushed_at=delivery.last_pushed_at,
                acked_at=delivery.acked_at,
                failed_at=delivery.failed_at,
            )
            for delivery in deliveries
        ],
        created_at=state.created_at,
        updated_at=state.updated_at,
    )


def _apply_remote_upsert(db: Session, change: SyncApplePullChange) -> tuple[str, str, Task | None]:
    mapping = db.scalar(
        select(AppleReminderMapping).where(AppleReminderMapping.apple_reminder_id == change.apple_reminder_id)
    )
    task = db.scalar(select(Task).where(Task.id == mapping.task_id)) if mapping else None

    if mapping and task:
        remote_modified_at = _normalize_dt(change.apple_modified_at)
        local_updated_at = _normalize_dt(task.updated_at)
        last_seen_apple_modified_at = _normalize_dt(mapping.last_seen_apple_modified_at)
        bridge_updated_at = _normalize_dt(mapping.bridge_updated_at)
        if task.sync_pending and remote_modified_at and last_seen_apple_modified_at and local_updated_at:
            if remote_modified_at > last_seen_apple_modified_at and (
                (bridge_updated_at is None or local_updated_at > bridge_updated_at)
                or (mapping.last_acked_change_id is not None and task.sync_change_id > mapping.last_acked_change_id)
            ):
                mapping.sync_state = SyncState.CONFLICT.value
                mapping.last_ack_status = "conflict"
                mapping.last_delivery_status = "conflict"
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
            last_delivery_status="acknowledged",
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
    mapping.last_delivery_status = "acknowledged"
    mapping.last_error_code = None
    mapping.last_error_message = None
    mapping.is_deleted_on_apple = False
    db.add(task)
    db.add(mapping)
    return "applied", "updated", task


@router.get("/apple/state/{bridge_id}", response_model=SyncBridgeStateRead)
def apple_state(bridge_id: str, db: Session = Depends(get_db)) -> SyncBridgeStateRead:
    state = _get_or_create_bridge_state(db, bridge_id)
    db.commit()
    db.refresh(state)
    return _serialize_bridge_state(state, db)


@router.post("/apple/pull")
def apple_pull(payload: SyncApplePullRequest, db: Session = Depends(get_db)) -> dict:
    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="running",
        started_at=_now(),
        stats={"mode": "pull", "limit": payload.limit, "cursor": payload.cursor},
    )
    db.add(run)
    state = _get_or_create_bridge_state(db, payload.bridge_id)
    state.last_pull_started_at = _now()
    state.last_pull_cursor = payload.cursor

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
            state.last_error_code = reason
            state.last_error_message = f"conflict on {change.apple_reminder_id}"
        results.append(
            {
                "apple_reminder_id": change.apple_reminder_id,
                "task_id": str(task.id) if task else None,
                "result": result,
                "reason": reason,
            }
        )
        next_cursor = isoformat_z(change.apple_modified_at) if change.apple_modified_at else next_cursor

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
    state.backend_cursor = next_cursor
    state.last_pull_succeeded_at = _now()
    if conflicts == 0:
        state.last_error_code = None
        state.last_error_message = None
    db.add(state)
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
        "checkpoint": _serialize_bridge_state(state, db).model_dump(mode="json"),
    }


@router.post("/apple/push")
def apple_push(payload: SyncApplePushRequest, db: Session = Depends(get_db)) -> dict:
    state = _get_or_create_bridge_state(db, payload.bridge_id)
    state.last_push_started_at = _now()
    if payload.cursor is not None:
        state.last_push_cursor = payload.cursor

    accepted = []
    created = 0
    requested_versions = {item.task_id: item.version for item in payload.tasks if item.task_id is not None}

    for item in payload.tasks:
        if item.task_id is not None:
            continue
        existing_mapping = db.scalar(
            select(AppleReminderMapping).where(AppleReminderMapping.apple_reminder_id == item.reminder_id)
        )
        if existing_mapping is not None:
            continue

        now = _now()
        is_completed = item.state == "completed"
        is_deleted = item.state == "deleted"
        task = Task(
            title=item.title,
            note=item.notes,
            status=TaskStatus.DELETED.value if is_deleted else (TaskStatus.COMPLETED.value if is_completed else TaskStatus.ACTIVE.value),
            bucket=TaskBucket.DONE.value if is_completed else TaskBucket.INBOX.value,
            priority=item.priority,
            due_at=_normalize_dt(item.due_date),
            remind_at=_normalize_dt(item.remind_at),
            completed_at=_normalize_dt(item.last_modified_at) if is_completed else None,
            deleted_at=_normalize_dt(item.last_modified_at) if is_deleted else None,
            source="apple_sync",
            source_ref=item.reminder_id,
            last_modified_by="apple_sync_push",
            is_all_day_due=item.is_all_day_due,
            sync_pending=False,
            sync_last_pushed_at=now,
        )
        db.add(task)
        db.flush()

        mapping = AppleReminderMapping(
            task_id=task.id,
            apple_reminder_id=item.reminder_id,
            apple_list_id=item.list_identifier,
            apple_calendar_id=item.list_identifier,
            last_synced_task_version=task.version,
            last_seen_apple_modified_at=_normalize_dt(item.last_modified_at),
            sync_state=SyncState.DELETED.value if is_deleted else SyncState.ACTIVE.value,
            pending_operation=None,
            last_push_change_id=task.sync_change_id,
            last_acked_change_id=task.sync_change_id,
            bridge_updated_at=now,
            last_ack_status="success",
            last_delivery_status="acknowledged",
            last_delivery_attempt_count=1,
            is_deleted_on_apple=is_deleted,
        )
        db.add(mapping)
        accepted.append(
            {
                "task_id": str(task.id),
                "version": task.version,
                "change_id": task.sync_change_id,
                "operation": _mapping_operation(mapping, task),
                "task": _serialize_push_item(task, mapping)["task"],
            }
        )
        created += 1

    replay_deliveries = list(
        db.scalars(
            select(SyncDelivery)
            .where(
                SyncDelivery.bridge_id == payload.bridge_id,
                SyncDelivery.status.in_(_replayable_delivery_statuses()),
            )
            .order_by(SyncDelivery.last_pushed_at.asc(), SyncDelivery.created_at.asc())
            .limit(payload.limit)
        ).all()
    )

    stmt = (
        select(Task, AppleReminderMapping)
        .outerjoin(AppleReminderMapping, AppleReminderMapping.task_id == Task.id)
        .where(or_(Task.sync_pending.is_(True), AppleReminderMapping.pending_operation.is_not(None)))
        .order_by(Task.sync_change_id.asc(), Task.updated_at.asc())
        .limit(payload.limit)
    )
    rows = list(db.execute(stmt).all())

    items = []
    replayed_keys: set[tuple[str, int]] = set()
    next_cursor = payload.cursor
    returned = 0
    max_seen_change_id = state.last_seen_change_id or 0

    for delivery in replay_deliveries:
        task = db.scalar(select(Task).where(Task.id == UUID(delivery.task_id)))
        if not task:
            continue
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == task.id))
        if (
            mapping
            and mapping.last_ack_status in {"success", "acked"}
            and mapping.last_acked_change_id == delivery.change_id
        ):
            continue
        requested_version = requested_versions.get(task.id)
        if requested_version is not None and requested_version >= task.version:
            continue
        items.append(_serialize_push_item(task, mapping))
        replayed_keys.add((str(task.id), delivery.change_id))
        returned += 1
        max_seen_change_id = max(max_seen_change_id, delivery.change_id)
        task.sync_last_pushed_at = _now()
        delivery.attempt_count += 1
        delivery.last_pushed_at = _now()
        delivery.status = "pending"
        delivery.failed_at = None
        delivery.acked_at = None
        delivery.task_version = task.version
        delivery.operation = _mapping_operation(mapping, task)
        if mapping:
            previous_delivery_status = mapping.last_delivery_status
            delivery.remote_id = mapping.apple_reminder_id or delivery.remote_id
            mapping.pending_operation = _mapping_operation(mapping, task)
            mapping.last_push_change_id = delivery.change_id
            mapping.last_delivery_status = previous_delivery_status if previous_delivery_status in {"retryable_failed", "failed", "conflict"} else "pending"
            mapping.last_delivery_attempt_count = delivery.attempt_count
            db.add(mapping)
        db.add(delivery)
        db.add(task)
        if returned >= payload.limit:
            break

    if returned < payload.limit:
        for task, mapping in rows:
            if (str(task.id), task.sync_change_id) in replayed_keys:
                continue
            if mapping and mapping.last_ack_status in {"success", "acked"} and mapping.last_acked_change_id == task.sync_change_id:
                continue
            if payload.cursor is not None and str(task.sync_change_id) <= payload.cursor:
                continue
            requested_version = requested_versions.get(task.id)
            if requested_version is not None and requested_version >= task.version:
                continue
            items.append(_serialize_push_item(task, mapping))
            returned += 1
            next_cursor = str(task.sync_change_id)
            max_seen_change_id = max(max_seen_change_id, task.sync_change_id)
            task.sync_last_pushed_at = _now()
            previous_delivery_status = mapping.last_delivery_status if mapping else None
            delivery = _get_or_create_delivery(
                db,
                bridge_id=payload.bridge_id,
                task_id=str(task.id),
                change_id=task.sync_change_id,
                version=task.version,
                operation=_mapping_operation(mapping, task),
                remote_id=mapping.apple_reminder_id if mapping else None,
            )
            if mapping:
                mapping.pending_operation = _mapping_operation(mapping, task)
                mapping.last_push_change_id = task.sync_change_id
                mapping.last_delivery_status = previous_delivery_status if previous_delivery_status in {"retryable_failed", "failed", "conflict"} else delivery.status
                mapping.last_delivery_attempt_count = delivery.attempt_count
                db.add(mapping)
            db.add(task)
            if returned >= payload.limit:
                break

    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=_now(),
        finished_at=_now(),
        stats={
            "mode": "push",
            "requested": len(payload.tasks),
            "accepted": len(accepted),
            "created": created,
            "returned": returned,
            "cursor": payload.cursor,
            "next_cursor": next_cursor,
        },
    )
    state.last_push_cursor = next_cursor
    state.last_push_succeeded_at = _now()
    state.last_seen_change_id = max(max_seen_change_id, *(entry["change_id"] for entry in accepted)) if accepted else (max_seen_change_id or state.last_seen_change_id)
    db.add(state)
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "push",
        "bridge_id": payload.bridge_id,
        "cursor": payload.cursor,
        "next_cursor": next_cursor,
        "accepted": accepted,
        "items": items,
        "checkpoint": _serialize_bridge_state(state, db).model_dump(mode="json"),
    }


@router.post("/apple/ack")
def apple_ack(payload: SyncAppleAckRequest, db: Session = Depends(get_db)) -> dict:
    state = _get_or_create_bridge_state(db, payload.bridge_id)
    state.last_ack_started_at = _now()

    acked = []
    success = 0
    failed = 0
    conflict = 0
    max_acked_change_id = state.last_acked_change_id or 0

    for item in payload.acks:
        task = db.scalar(select(Task).where(Task.id == item.task_id))
        if not task:
            raise HTTPException(status_code=404, detail=f"Task not found: {item.task_id}")

        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == item.task_id))
        if not mapping and item.remote_id:
            bootstrap_change_id = item.change_id or task.sync_change_id
            mapping = AppleReminderMapping(
                task_id=item.task_id,
                apple_reminder_id=item.remote_id,
                last_synced_task_version=item.version,
                last_seen_apple_modified_at=_normalize_dt(item.apple_modified_at),
                sync_state=SyncState.ACTIVE.value,
                last_push_change_id=bootstrap_change_id,
                last_acked_change_id=bootstrap_change_id if item.status in {"success", "acked"} else None,
                bridge_updated_at=_now(),
                last_delivery_status="acknowledged" if item.status in {"success", "acked"} else item.status,
            )
            db.add(mapping)
            db.flush()
        elif not mapping:
            raise HTTPException(status_code=404, detail=f"Mapping not found for task: {item.task_id}")

        if item.version > task.version:
            raise HTTPException(status_code=409, detail=f"Ack version ahead of task version for task: {item.task_id}")

        ack_change_id = item.change_id or mapping.last_push_change_id or mapping.last_acked_change_id or task.sync_change_id
        if ack_change_id > task.sync_change_id:
            raise HTTPException(status_code=409, detail=f"Ack change_id ahead of task change_id for task: {item.task_id}")
        if mapping.last_acked_change_id and ack_change_id <= mapping.last_acked_change_id:
            acked.append(
                {
                    "task_id": str(item.task_id),
                    "remote_id": mapping.apple_reminder_id,
                    "version": item.version,
                    "change_id": ack_change_id,
                    "status": "stale_ignored",
                }
            )
            continue
        if mapping.last_synced_task_version and item.version < mapping.last_synced_task_version:
            acked.append(
                {
                    "task_id": str(item.task_id),
                    "remote_id": mapping.apple_reminder_id,
                    "version": item.version,
                    "change_id": ack_change_id,
                    "status": "stale_ignored",
                }
            )
            continue

        delivery = db.scalar(
            select(SyncDelivery).where(
                SyncDelivery.bridge_id == payload.bridge_id,
                SyncDelivery.task_id == str(item.task_id),
                SyncDelivery.change_id == ack_change_id,
            )
        )
        if delivery is None and item.change_id is not None and mapping.last_acked_change_id == ack_change_id:
            acked.append(
                {
                    "task_id": str(item.task_id),
                    "remote_id": mapping.apple_reminder_id,
                    "version": item.version,
                    "change_id": ack_change_id,
                    "status": "stale_ignored",
                }
            )
            continue
        if delivery is None and item.change_id is not None and mapping.last_acked_change_id != ack_change_id:
            raise HTTPException(status_code=409, detail=f"Ack change_id not found for task: {item.task_id}")
        if delivery and item.version != delivery.task_version:
            raise HTTPException(status_code=409, detail=f"Ack version does not match delivered version for task: {item.task_id}")

        if item.remote_id:
            mapping.apple_reminder_id = item.remote_id
        mapping.apple_list_id = item.apple_list_id or mapping.apple_list_id
        mapping.apple_calendar_id = item.apple_calendar_id or mapping.apple_calendar_id
        mapping.last_seen_apple_modified_at = _normalize_dt(item.apple_modified_at) or mapping.last_seen_apple_modified_at
        mapping.bridge_updated_at = _now()
        mapping.last_ack_status = item.status
        mapping.last_error_code = item.error_code
        mapping.last_error_message = item.error_message

        effective_change_id = ack_change_id
        if delivery:
            delivery.remote_id = item.remote_id or delivery.remote_id
            delivery.retryable = item.retryable
            delivery.last_error_code = item.error_code
            delivery.last_error_message = item.error_message

        if item.status in {"success", "acked"}:
            success += 1
            task.sync_pending = False
            task.sync_last_pushed_at = _now()
            mapping.last_synced_task_version = task.version
            mapping.last_push_change_id = effective_change_id
            mapping.last_acked_change_id = effective_change_id
            mapping.last_failed_change_id = None
            mapping.pending_operation = None
            mapping.sync_state = SyncState.DELETED.value if _task_operation(task) == "delete" else SyncState.ACTIVE.value
            mapping.is_deleted_on_apple = _task_operation(task) == "delete"
            mapping.last_delivery_status = "acknowledged"
            mapping.last_delivery_attempt_count = delivery.attempt_count if delivery else mapping.last_delivery_attempt_count
            max_acked_change_id = max(max_acked_change_id, effective_change_id)
            state.last_acked_change_id = max(state.last_acked_change_id or 0, effective_change_id)
            if delivery:
                delivery.status = "acknowledged"
                delivery.acked_at = _now()
                delivery.failed_at = None
        elif item.status == "conflict":
            conflict += 1
            mapping.sync_state = SyncState.CONFLICT.value
            mapping.last_delivery_status = "conflict"
            mapping.last_failed_change_id = effective_change_id
            state.last_failed_change_id = max(state.last_failed_change_id or 0, effective_change_id)
            state.last_error_code = item.error_code or "conflict"
            state.last_error_message = item.error_message or f"conflict on task {item.task_id}"
            if delivery:
                delivery.status = "conflict"
                delivery.failed_at = _now()
        else:
            failed += 1
            task.sync_pending = True
            mapping.pending_operation = _task_operation(task)
            mapping.last_delivery_status = "retryable_failed" if item.retryable else "failed"
            mapping.last_delivery_attempt_count = delivery.attempt_count if delivery else mapping.last_delivery_attempt_count
            mapping.last_failed_change_id = effective_change_id
            state.last_failed_change_id = max(state.last_failed_change_id or 0, effective_change_id)
            state.last_error_code = item.error_code or ("retryable_push_failed" if item.retryable else "push_failed")
            state.last_error_message = item.error_message or f"ack failed on task {item.task_id}"
            if delivery:
                delivery.status = mapping.last_delivery_status
                delivery.failed_at = _now()

        db.add(task)
        db.add(mapping)
        if delivery:
            db.add(delivery)
        acked.append(
            {
                "task_id": str(item.task_id),
                "remote_id": mapping.apple_reminder_id,
                "version": item.version,
                "change_id": effective_change_id,
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
    state.last_ack_succeeded_at = _now()
    state.last_acked_change_id = max_acked_change_id or state.last_acked_change_id
    if payload.acks and failed == 0 and conflict == 0:
        state.last_error_code = None
        state.last_error_message = None
    db.add(state)
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
        "checkpoint": _serialize_bridge_state(state, db).model_dump(mode="json"),
    }
