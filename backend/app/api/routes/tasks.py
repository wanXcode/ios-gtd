from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_, select
from sqlalchemy.orm import Session, selectinload

from app.db.session import get_db
from app.models.tag import Tag
from app.models.task import Task
from app.schemas.task import TaskCreate, TaskRead, TaskUpdate

router = APIRouter()


def _task_query():
    return select(Task).options(selectinload(Task.project), selectinload(Task.tags))


def _apply_tags(db: Session, task: Task, tag_ids: list[UUID]) -> None:
    if not tag_ids:
        task.tags = []
        return
    tags = list(db.scalars(select(Tag).where(Tag.id.in_(tag_ids))).all())
    if len(tags) != len(set(tag_ids)):
        raise HTTPException(status_code=404, detail="One or more tags were not found")
    task.tags = tags


@router.get("", response_model=list[TaskRead])
def list_tasks(
    bucket: str | None = None,
    status_value: str | None = Query(default=None, alias="status"),
    project_id: UUID | None = None,
    due_before: datetime | None = None,
    due_after: datetime | None = None,
    updated_after: datetime | None = None,
    q: str | None = None,
    db: Session = Depends(get_db),
) -> list[Task]:
    stmt = _task_query().order_by(Task.updated_at.desc())
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
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query().where(Task.id == task.id))


@router.get("/{task_id}", response_model=TaskRead)
def get_task(task_id: UUID, db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query().where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.patch("/{task_id}", response_model=TaskRead)
def update_task(task_id: UUID, payload: TaskUpdate, db: Session = Depends(get_db)) -> Task:
    task = db.scalar(_task_query().where(Task.id == task_id))
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    updates = payload.model_dump(exclude_unset=True)
    tag_ids = updates.pop("tag_ids", None)
    for field, value in updates.items():
        setattr(task, field, value)
    if tag_ids is not None:
        _apply_tags(db, task, tag_ids)
    task.version += 1
    db.add(task)
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query().where(Task.id == task.id))


@router.post("/{task_id}/complete", response_model=TaskRead)
def complete_task(task_id: UUID, db: Session = Depends(get_db)) -> Task:
    task = db.get(Task, task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    task.status = "completed"
    task.bucket = "done"
    task.completed_at = datetime.now(timezone.utc)
    task.version += 1
    db.add(task)
    db.commit()
    db.refresh(task)
    return db.scalar(_task_query().where(Task.id == task.id))


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: UUID, db: Session = Depends(get_db)) -> None:
    task = db.get(Task, task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    db.delete(task)
    db.commit()
