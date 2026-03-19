from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.session import get_db
from app.main import app as fastapi_app
from app.models.operation_log import OperationLog
from app.models.task import Task


def make_test_client() -> tuple[TestClient, sessionmaker]:
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        future=True,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    testing_session_local = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)

    from app.db.base import Base
    import app.models  # noqa: F401

    Base.metadata.create_all(bind=engine)

    def override_get_db():
        db = testing_session_local()
        try:
            yield db
        finally:
            db.close()

    fastapi_app.dependency_overrides[get_db] = override_get_db
    return TestClient(fastapi_app), testing_session_local


client, TestingSessionLocal = make_test_client()


def test_health() -> None:
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_task_lifecycle_and_operation_logs() -> None:
    created = client.post("/api/tasks", json={"title": "Write deploy docs", "last_modified_by": "tester"})
    assert created.status_code == 201
    task = created.json()
    task_id = task["id"]

    completed = client.post(f"/api/tasks/{task_id}/complete", params={"actor": "tester"})
    assert completed.status_code == 200
    assert completed.json()["status"] == "completed"
    assert completed.json()["bucket"] == "done"

    reopened = client.post(f"/api/tasks/{task_id}/reopen", params={"actor": "tester"})
    assert reopened.status_code == 200
    assert reopened.json()["status"] == "active"
    assert reopened.json()["completed_at"] is None

    deleted = client.delete(f"/api/tasks/{task_id}", params={"actor": "tester"})
    assert deleted.status_code == 204

    list_default = client.get("/api/tasks")
    assert list_default.status_code == 200
    ids = {item["id"] for item in list_default.json()}
    assert task_id not in ids

    list_with_deleted = client.get("/api/tasks", params={"include_deleted": True})
    deleted_task = next(item for item in list_with_deleted.json() if item["id"] == task_id)
    assert deleted_task["status"] == "deleted"
    assert deleted_task["deleted_at"] is not None

    with TestingSessionLocal() as db:
        logs = list(db.scalars(select(OperationLog).order_by(OperationLog.created_at.asc())).all())
        ops = [log.operation_type for log in logs]
        assert "create" in ops
        assert "complete" in ops
        assert "reopen" in ops
        assert "delete" in ops


def test_batch_update_tasks() -> None:
    first = client.post("/api/tasks", json={"title": "Task A", "last_modified_by": "tester"}).json()
    second = client.post("/api/tasks", json={"title": "Task B", "last_modified_by": "tester"}).json()

    response = client.post(
        "/api/tasks/batch-update",
        json={
            "updates": [
                {"id": first["id"], "patch": {"bucket": "next", "priority": 3, "last_modified_by": "batcher"}},
                {"id": second["id"], "patch": {"status": "completed", "bucket": "done", "last_modified_by": "batcher"}},
            ]
        },
    )
    assert response.status_code == 200
    payload = response.json()
    assert len(payload) == 2

    with TestingSessionLocal() as db:
        first_db = db.scalar(select(Task).where(Task.id == UUID(first["id"])))
        second_db = db.scalar(select(Task).where(Task.id == UUID(second["id"])))
        assert first_db.bucket == "next"
        assert first_db.priority == 3
        assert second_db.status == "completed"
        logs = list(db.scalars(select(OperationLog).where(OperationLog.operation_type == "batch_update")).all())
        assert len(logs) >= 2


def test_sync_placeholders() -> None:
    task = client.post("/api/tasks", json={"title": "Sync me", "last_modified_by": "tester"}).json()

    pull = client.post("/api/sync/apple/pull", json={"bridge_id": "bridge-dev", "cursor": "c1", "limit": 10})
    assert pull.status_code == 200
    assert pull.json()["mode"] == "pull"

    push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-dev", "cursor": "c2", "tasks": [{"task_id": task["id"], "version": task["version"]}]},
    )
    assert push.status_code == 200
    assert push.json()["mode"] == "push"
    assert len(push.json()["items"]) == 1
    assert push.json()["items"][0]["task_id"] == task["id"]

    ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dev",
            "acks": [{"task_id": task["id"], "remote_id": "apple-1", "version": task["version"], "status": "acked"}],
        },
    )
    assert ack.status_code == 200
    assert ack.json()["mode"] == "ack"
    assert ack.json()["acked"][0]["remote_id"] == "apple-1"


def test_assistant_capture_dry_run_and_persist() -> None:
    dry_run = client.post(
        "/api/assistant/capture",
        json={
            "input": "明天提醒我发合同",
            "context": {"timezone": "Asia/Shanghai", "source": "chat", "source_ref": "msg-1", "actor": "tester"},
            "dry_run": True,
        },
    )
    assert dry_run.status_code == 200
    dry_payload = dry_run.json()
    assert dry_payload["dry_run"] is True
    assert dry_payload["task"] is None
    assert dry_payload["parsed"]["title"] == "发合同"
    assert dry_payload["parsed"]["due_at"] is not None

    persisted = client.post(
        "/api/assistant/capture",
        json={
            "input": "下周前把合同发出去",
            "context": {"timezone": "Asia/Shanghai", "source": "chat", "source_ref": "msg-2", "actor": "tester"},
            "dry_run": False,
        },
    )
    assert persisted.status_code == 200
    payload = persisted.json()
    assert payload["task"]["id"]
    assert payload["task"]["bucket"] == "inbox"
    assert payload["task"]["status"] == "active"
    assert payload["task"]["source"] == "chat"
    assert payload["task"]["source_ref"] == "msg-2"
    assert payload["parsed"]["title"] == "把合同发出去"

    tasks = client.get("/api/tasks").json()
    assert any(item["id"] == payload["task"]["id"] for item in tasks)


def test_assistant_views_today_and_waiting() -> None:
    today_task = client.post(
        "/api/tasks",
        json={"title": "Today task", "bucket": "next", "due_at": "2026-03-19T09:00:00Z", "last_modified_by": "tester"},
    ).json()
    overdue_task = client.post(
        "/api/tasks",
        json={"title": "Overdue task", "bucket": "next", "due_at": "2026-03-18T09:00:00Z", "last_modified_by": "tester"},
    ).json()
    future_task = client.post(
        "/api/tasks",
        json={"title": "Future task", "bucket": "next", "due_at": "2026-03-21T09:00:00Z", "last_modified_by": "tester"},
    ).json()
    waiting_task = client.post(
        "/api/tasks",
        json={"title": "Waiting task", "bucket": "waiting", "last_modified_by": "tester"},
    ).json()

    from unittest.mock import patch
    from datetime import datetime
    from app.services import assistant as assistant_service

    fake_now = datetime(2026, 3, 19, 8, 0, 0)

    class FrozenDateTime(datetime):
        @classmethod
        def now(cls, tz=None):
            if tz is None:
                return fake_now
            return fake_now.replace(tzinfo=tz)

    with patch.object(assistant_service, "datetime", FrozenDateTime):
        today = client.get("/api/assistant/views/today", params={"timezone": "UTC", "include_overdue": True})
        assert today.status_code == 200
        today_ids = {item["id"] for item in today.json()["items"]}
        assert today_task["id"] in today_ids
        assert overdue_task["id"] in today_ids
        assert future_task["id"] not in today_ids

        today_no_overdue = client.get("/api/assistant/views/today", params={"timezone": "UTC", "include_overdue": False})
        ids_no_overdue = {item["id"] for item in today_no_overdue.json()["items"]}
        assert today_task["id"] in ids_no_overdue
        assert overdue_task["id"] not in ids_no_overdue

    waiting = client.get("/api/assistant/views/waiting")
    assert waiting.status_code == 200
    waiting_ids = {item["id"] for item in waiting.json()["items"]}
    assert waiting_task["id"] in waiting_ids
    assert today_task["id"] not in waiting_ids
    assert future_task["id"] not in waiting_ids
