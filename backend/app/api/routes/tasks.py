from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, select
from sqlalchemy.orm import Session, selectinload

from app.db.session import get_db
from app.models.enums import TaskBucket, TaskStatus
from app.models.operation_log import OperationLog
from app.models.tag import Tag
from app.models.task import Task
from app.schemas.task import TaskBatchUpdateRequest, TaskCreate, TaskRead, TaskUpdate

router = APIRouter()


SOFT_DELETE_DEFAULT = True


def _task_query(include_deleted: bool = False):
    stmt = select(Task).options(selectinload(Task.project), selectinload(Task.tags))
    if not include_deleted:
        stmt = stmt.where(Task.deleted_at.is_(None))
    return stmt


def _apply_tags(db: Session, task: Task, tag_ids: list[UUID]) -> None:
    if not tag_ids:
        task.tags = []
        return
    tags = list(db.scalars(select(Tag).where(Tag.id.in_(tag_ids))).all())
    if len(tags) != len(set(tag_ids)):
        raise HTTPException(status_code=404, detail="One or more tags were not found")
    task.tags = tags


def _serialize_task(task: Task) -> dict:
    return {
        "id": str(task.id),
        "title": task.title,
        "status": task.status,
        "bucket": task.bucket,
        "priority": task.priority,
        "project_id": str(task.project_id) if task.project_id else None,
        "tag_ids": [str(tag.id) for tag in task.tags],
        "due_at": task.due_at.isoformat() if task.due_at else None,
        "remind_at": task.remind_at.isoformat() if task.remind_at else None,
        "completed_at": task.completed_at.isoformat() if task.completed_at else None,
        "deleted_at": task.deleted_at.isoformat() if task.deleted_at else None,
        "version": task.version,
        "last_modified_by": task.last_modified_by,
    }


def _log_operation(
    db: Session,
    *,
    task: Task | None,
    operation_type: str,
    actor: str,
    source: str = "api",
    payload: dict | None = None,
) -> None:
    db.add(
        OperationLog(
            task_id=task.id if task else None,
            operation_type=operation_type,
            actor=actor,
            source=source,
            payload=payload or {},
        )
    )


def _touch_task(task: Task, actor: str | None) -> None:
    if actor:
        task.last_modified_by = actor
    task.version += 1


def _apply_task_updates(db: Session, task: Task, payload: TaskUpdate) -> dict:
    updates = payload.model_dump(exclude_unset=True)
    tag_ids = updates.pop("tag_ids", None)
    actor = updates.get("last_modified_by") or task.last_modified_by
    before = _serialize_task(task)

    for field, value in updates.items():
        setattr(task, field, value)

    if tag_ids is not None:
        _apply_tags(db, task, tag_ids)

    if "status" in updates and updates["status"] == TaskStatus.COMPLETED.value and task.completed_at is None:
        task.completed_at = datetime.now(timezone.utc)
    if "status" in updates and updates["status"] != TaskStatus.COMPLETED.value:
        task.completed_at = updates.get("completed_at", None)
    if "deleted_at" in updates and updates["deleted_at"] is not None:
        task.status = TaskStatus.DELETED.value
    if "deleted_at" in updates and updates["deleted_at"] is None and task.status == TaskStatus.DELETED.value:
        task.status = TaskStatus.ACTIVE.value

    _touch_task(task, actor)
    return {"before": before, "after": _serialize_task(task), "actor": actor}


@router.get("", response_model=list[TaskRead])
def list_tasks(
    bucket: str | None = None,
    status_value: str | None = Query(default=None, alias="status"),
    project_id: UUID | None = None,
    due_before: datetime | None = None,
    due_after: datetime | None = None,
    updated_after: datetime | None = None,
    q: str | None = None,
    include_deleted: bool = False,
    db: Session = Depends(get_db),
) -> list[Task]:
    stmt = _task_query(include_deleted=include_deleted).order_by(Task.updated_at.desc())
    if bucket:
        stmt = stmt.where(Task.bucket == bucket)
    if status_value:
        stmt = stmt.where(Task.status == status_value)
    if project_id:
        stmt = stmt.where(Task.project_id == project_id)
    if due_before:
        stmt = stmt.where(Task.due_at.is_not(None), Task.due_at <= due_before)
    if due_after:
        stmt = stmt.where(Task.due_at.is_not(None), Task.due_at >= due_after)
    if updated_after:
        stmt = stmt.where(Task.updated_at >= updated_after)
    if q:
        like = f"%{q}%"
        stmt = stmt.where(or_(Task.title.ilike(like), Task.note.ilike(like)))
    return list(db.scalars(stmt).unique().all())


@router.post("", response_model=TaskRead, status_code=status.HTTP_201_CREATED)
def create_task(payload: TaskCreate, db: Session = Depends(get_db)) -> Task:
    task = Task(
        title=payload.title,
        note=payload.note,
        status=payload.status,
        bucket=payload.bucket,
        priority=payload.priority,
        due_at=payload.due_at,
        remind_at=payload.remind_at,
        source=payload.source,
        source_ref=payload.source_ref,
        project_id=payload.project_id,
        last_modified_by=payload.last_modified_by,
    )
    _apply_tags(db, task, payload.tag_ids)
    db.add(task)
    db.flush()
    db.refresh(task)
    _log_operation(
        db,
        task=task,
        operation_type="create",
        actor=payload.last_modified_by,
        payload={"after": _serialize_task(task)},
    )
    db.commit()
    return db.scalar(_task_query(include_deleted=True).where(Task.id == task.id))


@router.get("/{task_id}", response_model=TaskRead)
def get_task(task_id: UUID, include_deleted: bool = False, db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query(include_deleted=include_deleted).where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.patch("/{task_id}", response_model=TaskRead)
def update_task(task_id: UUID, payload: TaskUpdate, db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query(include_deleted=True).where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    details = _apply_task_updates(db, task, payload)
    db.add(task)
    _log_operation(
        db,
        task=task,
        operation_type="update",
        actor=details["actor"] or task.last_modified_by,
        payload={"before": details["before"], "after": details["after"]},
    )
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query(include_deleted=True).where(Task.id == task.id))


@router.post("/batch-update", response_model=list[TaskRead])
def batch_update_tasks(payload: TaskBatchUpdateRequest, db: Session = Depends(get_db)) -> list[Task]:
    updated_ids: list[UUID] = []
    for item in payload.updates:
        task = db.scalar(_task_query(include_deleted=True).where(Task.id == item.id))
        if not task:
            raise HTTPException(status_code=404, detail=f"Task not found: {item.id}")
        details = _apply_task_updates(db, task, item.patch)
        db.add(task)
        _log_operation(
            db,
            task=task,
            operation_type="batch_update",
            actor=details["actor"] or task.last_modified_by,
            payload={"before": details["before"], "after": details["after"]},
        )
        updated_ids.append(task.id)

    db.commit()
    stmt = _task_query(include_deleted=True).where(Task.id.in_(updated_ids)).order_by(Task.updated_at.desc())
    return list(db.scalars(stmt).unique().all())


@router.post("/{task_id}/complete", response_model=TaskRead)
def complete_task(task_id: UUID, actor: str = Query(default="api"), db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query(include_deleted=True).where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    before = _serialize_task(task)
    task.status = TaskStatus.COMPLETED.value
    task.bucket = TaskBucket.DONE.value
    task.completed_at = datetime.now(timezone.utc)
    _touch_task(task, actor)
    db.add(task)
    _log_operation(
        db,
        task=task,
        operation_type="complete",
        actor=actor,
        payload={"before": before, "after": _serialize_task(task)},
    )
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query(include_deleted=True).where(Task.id == task.id))


@router.post("/{task_id}/reopen", response_model=TaskRead)
def reopen_task(task_id: UUID, actor: str = Query(default="api"), db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query(include_deleted=True).where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    before = _serialize_task(task)
    task.status = TaskStatus.ACTIVE.value
    task.bucket = TaskBucket.INBOX.value if task.bucket == TaskBucket.DONE.value else task.bucket
    task.completed_at = None
    task.deleted_at = None
    _touch_task(task, actor)
    db.add(task)
    _log_operation(
        db,
        task=task,
        operation_type="reopen",
        actor=actor,
        payload={"before": before, "after": _serialize_task(task)},
    )
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query(include_deleted=True).where(Task.id == task.id))


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(
    task_id: UUID,
    actor: str = Query(default="api"),
    hard: bool = Query(default=False),
    db: Session = Depends(get_db),
) -> None:
    task = db.scalar(_task_query(include_deleted=True).where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    if hard and not SOFT_DELETE_DEFAULT:
        before = _serialize_task(task)
        _log_operation(
            db,
            task=task,
            operation_type="delete",
            actor=actor,
            payload={"mode": "hard", "before": before},
        )
        db.delete(task)
        db.commit()
        return

    before = _serialize_task(task)
    task.deleted_at = datetime.now(timezone.utc)
    task.status = TaskStatus.DELETED.value
    task.completed_at = None
    _touch_task(task, actor)
    db.add(task)
    _log_operation(
        db,
        task=task,
        operation_type="delete",
        actor=actor,
        payload={"mode": "soft", "before": before, "after": _serialize_task(task)},
    )
    db.commit()
