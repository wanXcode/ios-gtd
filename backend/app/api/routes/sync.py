from datetime import datetime, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.apple_mapping import AppleReminderMapping
from app.models.sync_run import SyncRun
from app.models.task import Task
from app.schemas.sync import SyncAppleAckRequest, SyncApplePullRequest, SyncApplePushRequest

router = APIRouter()


@router.post("/apple/pull")
def apple_pull(payload: SyncApplePullRequest, db: Session = Depends(get_db)) -> dict:
    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
        stats={"mode": "pull", "limit": payload.limit, "cursor": payload.cursor},
    )
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "pull",
        "bridge_id": payload.bridge_id,
        "cursor": payload.cursor,
        "next_cursor": payload.cursor,
        "items": [],
        "message": "sync pull placeholder is ready for bridge integration",
    }


@router.post("/apple/push")
def apple_push(payload: SyncApplePushRequest, db: Session = Depends(get_db)) -> dict:
    task_ids = [item.task_id for item in payload.tasks]
    tasks = []
    if task_ids:
        stmt = select(Task).where(Task.id.in_(task_ids))
        tasks = list(db.scalars(stmt).all())

    items = [
        {
            "task_id": str(task.id),
            "version": task.version,
            "title": task.title,
            "status": task.status,
            "deleted": task.deleted_at is not None,
            "last_modified_by": task.last_modified_by,
        }
        for task in tasks
    ]

    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
        stats={"mode": "push", "requested": len(payload.tasks), "returned": len(items), "cursor": payload.cursor},
    )
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "push",
        "bridge_id": payload.bridge_id,
        "cursor": payload.cursor,
        "next_cursor": payload.cursor,
        "items": items,
        "message": "sync push placeholder is ready for bridge integration",
    }


@router.post("/apple/ack")
def apple_ack(payload: SyncAppleAckRequest, db: Session = Depends(get_db)) -> dict:
    acked = []
    for item in payload.acks:
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == item.task_id))
        if not mapping and item.remote_id:
            mapping = AppleReminderMapping(
                task_id=item.task_id,
                apple_reminder_id=item.remote_id,
                last_synced_task_version=item.version,
                last_seen_apple_modified_at=item.apple_modified_at,
            )
            db.add(mapping)
        elif mapping:
            if item.remote_id:
                mapping.apple_reminder_id = item.remote_id
            mapping.last_synced_task_version = item.version
            mapping.last_seen_apple_modified_at = item.apple_modified_at
            db.add(mapping)
        acked.append(
            {
                "task_id": str(item.task_id),
                "remote_id": item.remote_id,
                "version": item.version,
                "status": item.status,
            }
        )

    run = SyncRun(
        bridge_id=payload.bridge_id,
        status="success",
        started_at=datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
        stats={"mode": "ack", "acked": len(acked)},
    )
    db.add(run)
    db.commit()
    return {
        "ok": True,
        "mode": "ack",
        "bridge_id": payload.bridge_id,
        "acked": acked,
        "message": "sync ack placeholder recorded mappings",
    }
