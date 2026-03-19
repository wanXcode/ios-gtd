from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.session import get_db
from app.main import app as fastapi_app
from app.models.apple_mapping import AppleReminderMapping
from app.models.operation_log import OperationLog
from app.models.sync_bridge_state import SyncBridgeState
from app.models.sync_delivery import SyncDelivery
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
    created = client.post(
        "/api/tasks", json={"title": "Write deploy docs", "last_modified_by": "tester", "is_all_day_due": True}
    )
    assert created.status_code == 201
    task = created.json()
    task_id = task["id"]
    assert task["sync_pending"] is True
    assert task["is_all_day_due"] is True

    completed = client.post(f"/api/tasks/{task_id}/complete", params={"actor": "tester"})
    assert completed.status_code == 200
    assert completed.json()["status"] == "completed"
    assert completed.json()["bucket"] == "done"
    assert completed.json()["sync_change_id"] >= 2

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
                {
                    "id": first["id"],
                    "patch": {
                        "bucket": "next",
                        "priority": 3,
                        "last_modified_by": "batcher",
                        "is_all_day_due": True,
                    },
                },
                {
                    "id": second["id"],
                    "patch": {"status": "completed", "bucket": "done", "last_modified_by": "batcher"},
                },
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
        assert first_db.is_all_day_due is True
        assert second_db.status == "completed"
        logs = list(db.scalars(select(OperationLog).where(OperationLog.operation_type == "batch_update")).all())
        assert len(logs) >= 2


def test_sync_pull_push_ack_flow() -> None:
    remote_pull = client.post(
        "/api/sync/apple/pull",
        json={
            "bridge_id": "bridge-dev",
            "cursor": "c1",
            "limit": 10,
            "changes": [
                {
                    "change_type": "upsert",
                    "apple_reminder_id": "apple-remote-1",
                    "apple_list_id": "list-1",
                    "apple_calendar_id": "cal-1",
                    "apple_modified_at": "2026-03-19T04:00:00Z",
                    "payload": {
                        "title": "Pulled from Apple",
                        "note": "remote note",
                        "is_completed": False,
                        "due_at": "2026-03-20T09:00:00Z",
                        "remind_at": None,
                        "is_all_day_due": True,
                        "priority": 6,
                        "list_name": "Inbox",
                    },
                }
            ],
        },
    )
    assert remote_pull.status_code == 200
    pull_payload = remote_pull.json()
    assert pull_payload["accepted"] == 1
    assert pull_payload["applied"] == 1
    assert pull_payload["checkpoint"]["backend_cursor"] == "2026-03-19T04:00:00+00:00"
    task_id = pull_payload["results"][0]["task_id"]

    fetched = client.get(f"/api/tasks/{task_id}", params={"include_deleted": True}).json()
    assert fetched["title"] == "Pulled from Apple"
    assert fetched["sync_pending"] is False
    assert fetched["is_all_day_due"] is True

    updated = client.patch(
        f"/api/tasks/{task_id}",
        json={"title": "Locally changed", "last_modified_by": "tester", "bucket": "next"},
    )
    assert updated.status_code == 200
    assert updated.json()["sync_pending"] is True

    push = client.post("/api/sync/apple/push", json={"bridge_id": "bridge-dev", "cursor": "0", "limit": 10, "tasks": []})
    assert push.status_code == 200
    push_payload = push.json()
    assert push_payload["mode"] == "push"
    assert len(push_payload["items"]) >= 1
    item = next(entry for entry in push_payload["items"] if entry["task_id"] == task_id)
    assert item["operation"] == "upsert"
    assert item["task"]["title"] == "Locally changed"
    assert item["change_id"] >= 2
    assert int(push_payload["checkpoint"]["last_push_cursor"]) >= item["change_id"]

    ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dev",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-remote-1",
                    "version": item["version"],
                    "change_id": item["change_id"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T05:00:00Z",
                    "apple_list_id": "list-1",
                    "apple_calendar_id": "cal-1",
                }
            ],
        },
    )
    assert ack.status_code == 200
    ack_payload = ack.json()
    assert ack_payload["success"] == 1
    assert ack_payload["checkpoint"]["last_acked_change_id"] == item["change_id"]

    with TestingSessionLocal() as db:
        task = db.scalar(select(Task).where(Task.id == UUID(task_id)))
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == UUID(task_id)))
        delivery = db.scalar(
            select(SyncDelivery).where(
                SyncDelivery.bridge_id == "bridge-dev",
                SyncDelivery.task_id == task_id,
                SyncDelivery.change_id == item["change_id"],
            )
        )
        state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == "bridge-dev"))
        assert task.sync_pending is False
        assert mapping.last_synced_task_version == task.version
        assert mapping.apple_reminder_id == "apple-remote-1"
        assert mapping.pending_operation is None
        assert mapping.last_acked_change_id == item["change_id"]
        assert mapping.last_delivery_status == "acknowledged"
        assert delivery is not None
        assert delivery.status == "acknowledged"
        assert delivery.task_version == item["version"]
        assert state.backend_cursor == "2026-03-19T04:00:00+00:00"
        assert int(state.last_push_cursor) >= item["change_id"]
        assert state.last_acked_change_id >= item["change_id"]


def test_sync_pull_delete_marks_task_deleted() -> None:
    created = client.post("/api/tasks", json={"title": "Delete me via apple", "last_modified_by": "tester"}).json()
    task_id = created["id"]

    ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dev",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-delete-1",
                    "version": created["version"],
                    "change_id": created["sync_change_id"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T06:00:00Z",
                }
            ],
        },
    )
    assert ack.status_code == 200

    deleted = client.post(
        "/api/sync/apple/pull",
        json={
            "bridge_id": "bridge-dev",
            "cursor": "c-del",
            "limit": 10,
            "changes": [
                {
                    "change_type": "delete",
                    "apple_reminder_id": "apple-delete-1",
                    "apple_modified_at": "2026-03-19T06:30:00Z",
                }
            ],
        },
    )
    assert deleted.status_code == 200
    payload = deleted.json()
    assert payload["applied"] == 1

    task = client.get(f"/api/tasks/{task_id}", params={"include_deleted": True}).json()
    assert task["status"] == "deleted"
    assert task["deleted_at"] is not None


def test_sync_ack_stale_version_is_ignored_and_push_cursor_filters_duplicates() -> None:
    created = client.post("/api/tasks", json={"title": "Dedup me", "last_modified_by": "tester"}).json()
    task_id = created["id"]

    first_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-dedup", "cursor": "0", "limit": 10, "tasks": []},
    )
    assert first_push.status_code == 200
    first_item = next(entry for entry in first_push.json()["items"] if entry["task_id"] == task_id)

    first_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dedup",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-dedup-1",
                    "version": first_item["version"],
                    "change_id": first_item["change_id"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T07:00:00Z",
                }
            ],
        },
    )
    assert first_ack.status_code == 200

    stale_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dedup",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-dedup-1",
                    "version": first_item["version"] - 1,
                    "change_id": first_item["change_id"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T07:01:00Z",
                }
            ],
        },
    )
    assert stale_ack.status_code == 200
    assert stale_ack.json()["acked"][0]["status"] == "stale_ignored"

    updated = client.patch(
        f"/api/tasks/{task_id}",
        json={"title": "Dedup me again", "last_modified_by": "tester"},
    )
    assert updated.status_code == 200
    next_change_id = updated.json()["sync_change_id"]

    second_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-dedup", "cursor": str(next_change_id - 1), "limit": 10, "tasks": []},
    )
    assert second_push.status_code == 200
    assert any(entry["task_id"] == task_id for entry in second_push.json()["items"])

    filtered_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-dedup", "cursor": str(next_change_id), "limit": 10, "tasks": []},
    )
    assert filtered_push.status_code == 200
    assert all(entry["task_id"] != task_id for entry in filtered_push.json()["items"])


def test_sync_pull_conflict_path_marks_conflict_instead_of_datetime_typeerror() -> None:
    created = client.post("/api/tasks", json={"title": "Conflict me", "last_modified_by": "tester"}).json()
    task_id = created["id"]

    seeded = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-conflict",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-conflict-1",
                    "version": created["version"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T07:00:00Z",
                }
            ],
        },
    )
    assert seeded.status_code == 200

    updated = client.patch(
        f"/api/tasks/{task_id}",
        json={"title": "Local changed after sync", "last_modified_by": "tester"},
    )
    assert updated.status_code == 200

    conflicted = client.post(
        "/api/sync/apple/pull",
        json={
            "bridge_id": "bridge-conflict",
            "cursor": "c-conflict",
            "limit": 10,
            "changes": [
                {
                    "change_type": "upsert",
                    "apple_reminder_id": "apple-conflict-1",
                    "apple_list_id": "list-1",
                    "apple_calendar_id": "cal-1",
                    "apple_modified_at": "2026-03-19T08:00:00Z",
                    "payload": {
                        "title": "Remote changed after sync",
                        "note": "remote note",
                        "is_completed": False,
                        "due_at": None,
                        "remind_at": None,
                        "is_all_day_due": False,
                        "priority": 5,
                        "list_name": "Inbox",
                    },
                }
            ],
        },
    )
    assert conflicted.status_code == 200
    payload = conflicted.json()
    assert payload["conflicts"] == 1
    assert payload["results"][0]["result"] == "conflict"
    assert payload["results"][0]["reason"] == "task_modified_after_last_sync"


def test_sync_bridge_state_endpoint_returns_checkpoint_snapshot() -> None:
    response = client.get("/api/sync/apple/state/bridge-state-check")
    assert response.status_code == 200
    payload = response.json()
    assert payload["bridge_id"] == "bridge-state-check"
    assert payload["backend_cursor"] is None
    assert payload["last_acked_change_id"] is None
