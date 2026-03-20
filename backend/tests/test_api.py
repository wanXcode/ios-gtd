from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import sessionmaker

from app.models.apple_mapping import AppleReminderMapping
from app.models.operation_log import OperationLog
from app.models.sync_bridge_state import SyncBridgeState
from app.models.sync_delivery import SyncDelivery
from app.models.task import Task
from app.services.assistant import parse_capture_input


def test_health(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_task_lifecycle_and_operation_logs(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
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


def test_batch_update_tasks(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
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


def test_sync_pull_push_ack_flow(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
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
    assert pull_payload["checkpoint"]["backend_cursor"] == "2026-03-19T04:00:00Z"
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
        assert state.backend_cursor == "2026-03-19T04:00:00Z"
        assert int(state.last_push_cursor) >= item["change_id"]
        assert state.last_acked_change_id >= item["change_id"]


def test_sync_pull_delete_marks_task_deleted(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
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


def test_sync_ack_stale_version_is_ignored_and_push_cursor_filters_duplicates(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context
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
    filtered_items = [entry for entry in filtered_push.json()["items"] if entry["task_id"] == task_id]
    assert filtered_items
    assert all(entry["change_id"] == next_change_id for entry in filtered_items)

    ack_latest = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-dedup",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-dedup-1",
                    "version": updated.json()["version"],
                    "change_id": next_change_id,
                    "status": "success",
                    "apple_modified_at": "2026-03-19T07:02:00Z",
                }
            ],
        },
    )
    assert ack_latest.status_code == 200

    state = client.get("/api/sync/apple/state/bridge-dedup")
    assert state.status_code == 200
    state_payload = state.json()
    assert all(
        not (
            entry["task_id"] == task_id
            and entry["change_id"] == next_change_id
            and entry["status"] == "pending"
        )
        for entry in state_payload["recent_deliveries"]
    )


def test_sync_push_accepts_create_mutation_without_task_id(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context

    push = client.post(
        "/api/sync/apple/push",
        json={
            "bridge_id": "bridge-create-mutation",
            "cursor": "0",
            "limit": 10,
            "tasks": [
                {
                    "task_id": None,
                    "reminder_id": "apple-new-1",
                    "title": "Brand new reminder",
                    "notes": "first push from bridge",
                    "due_date": None,
                    "remind_at": None,
                    "is_all_day_due": False,
                    "priority": None,
                    "list_name": "Inbox",
                    "list_identifier": "inbox",
                    "external_identifier": "ek-apple-new-1",
                    "state": "active",
                    "fingerprint": {"value": "fp-apple-new-1"},
                    "last_modified_at": "2026-03-19T08:00:00Z",
                    "backend_version_token": None,
                    "backend_change_id": None,
                }
            ],
        },
    )
    assert push.status_code == 200
    payload = push.json()
    assert payload["mode"] == "push"
    assert len(payload["accepted"]) == 1
    assert payload["accepted"][0]["task"]["title"] == "Brand new reminder"
    assert payload["accepted"][0]["task"]["source_ref"] == "apple-new-1"
    assert payload["items"] == []
    assert payload["checkpoint"]["last_push_cursor"] == "0"


def test_sync_push_serializes_dates_with_utc_z_suffix(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context

    push = client.post(
        "/api/sync/apple/push",
        json={
            "bridge_id": "bridge-create-zulu",
            "cursor": "0",
            "limit": 10,
            "tasks": [
                {
                    "task_id": None,
                    "reminder_id": "apple-new-z-1",
                    "title": "Brand new reminder zulu",
                    "notes": "first push from bridge",
                    "due_date": "2026-03-19T10:00:00",
                    "remind_at": "2026-03-19T09:45:00.200718",
                    "is_all_day_due": False,
                    "priority": None,
                    "list_name": "Inbox",
                    "list_identifier": "inbox",
                    "external_identifier": "ek-apple-new-z-1",
                    "state": "active",
                    "fingerprint": {"value": "fp-apple-new-z-1"},
                    "last_modified_at": "2026-03-19T16:54:04.200718",
                    "backend_version_token": None,
                    "backend_change_id": None,
                }
            ],
        },
    )
    assert push.status_code == 200
    payload = push.json()
    accepted_task = payload["accepted"][0]["task"]
    assert accepted_task["due_at"] == "2026-03-19T10:00:00Z"
    assert accepted_task["remind_at"] == "2026-03-19T09:45:00.200718Z"
    assert accepted_task["updated_at"].endswith("Z")
    assert payload["checkpoint"]["created_at"].endswith("Z")
    assert payload["checkpoint"]["updated_at"].endswith("Z")


def test_sync_pull_conflict_path_marks_conflict_instead_of_datetime_typeerror(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
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


def test_sync_bridge_state_endpoint_returns_checkpoint_snapshot(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, TestingSessionLocal = test_context
    response = client.get("/api/sync/apple/state/bridge-state-check")
    assert response.status_code == 200
    payload = response.json()
    assert payload["bridge_id"] == "bridge-state-check"
    assert payload["backend_cursor"] is None
    assert payload["last_acked_change_id"] is None
    assert payload["pending_delivery_count"] == 0
    assert payload["recent_deliveries"] == []


def test_sync_pull_pairs_feishu_origin_task_by_source_record_id_instead_of_creating_duplicate(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context
    created = client.post(
        "/api/tasks",
        json={
            "title": "明晚8点提醒我给张三发合同",
            "last_modified_by": "tester",
            "source": "chat_ai",
            "source_ref": "msg-feishu-123",
        },
    )
    assert created.status_code == 201
    task_id = created.json()["id"]

    ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-echo-pairing",
            "acks": [
                {
                    "task_id": task_id,
                    "remote_id": "apple-reminder-echo-1",
                    "version": created.json()["version"],
                    "change_id": created.json()["sync_change_id"],
                    "status": "success",
                    "apple_modified_at": "2026-03-19T10:00:00Z",
                    "apple_list_id": "list-inbox",
                    "apple_calendar_id": "cal-inbox",
                }
            ],
        },
    )
    assert ack.status_code == 200

    pulled = client.post(
        "/api/sync/apple/pull",
        json={
            "bridge_id": "bridge-echo-pairing",
            "cursor": "c-echo-1",
            "limit": 10,
            "changes": [
                {
                    "change_type": "upsert",
                    "apple_reminder_id": "apple-reminder-echo-1",
                    "source_record_id": "msg-feishu-123",
                    "external_identifier": "msg-feishu-123",
                    "apple_list_id": "list-inbox",
                    "apple_calendar_id": "cal-inbox",
                    "apple_modified_at": "2026-03-19T10:00:03Z",
                    "payload": {
                        "title": "明晚8点提醒我给张三发合同",
                        "note": None,
                        "is_completed": False,
                        "due_at": None,
                        "remind_at": None,
                        "is_all_day_due": False,
                        "priority": None,
                        "list_name": "Inbox",
                    },
                }
            ],
        },
    )
    assert pulled.status_code == 200, pulled.text
    payload = pulled.json()
    assert payload["accepted"] == 1
    assert payload["applied"] == 1
    assert payload["results"][0]["task_id"] == task_id
    assert payload["results"][0]["reason"] in {"updated", "created"}

    with TestingSessionLocal() as db:
        tasks = list(db.scalars(select(Task).order_by(Task.created_at.asc())).all())
        assert len(tasks) == 1
        assert str(tasks[0].id) == task_id
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == UUID(task_id)))
        assert mapping is not None
        assert mapping.apple_reminder_id == "apple-reminder-echo-1"
        refreshed = db.scalar(select(Task).where(Task.id == UUID(task_id)))
        assert refreshed.source_ref == "msg-feishu-123"
        assert refreshed.last_modified_by == "apple_sync"


def test_capture_api_apply_false_returns_structured_draft(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context

    response = client.post(
        "/api/assistant/capture",
        json={
            "input": "明晚8点给妈妈打电话",
            "context": {"timezone": "UTC", "actor": "tester"},
            "apply": False,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["created"] is None
    assert payload["applied"] is False
    assert payload["draft"]["intent"] == "create_task"
    assert payload["draft"]["summary"] == "给妈妈打电话"
    assert payload["draft"]["bucket"] == "next"
    assert payload["draft"]["needs_confirmation"] is False
    assert payload["draft"]["questions"] == []
    assert payload["draft"]["error_code"] is None
    assert payload["questions"] == []
    assert payload["error_code"] is None
    assert payload["draft"]["due_at"].endswith("Z")
    assert payload["draft"]["remind_at"].endswith("Z")


def test_parse_capture_input_is_deterministic_for_relative_time() -> None:
    parsed = parse_capture_input("以后再说 下周整理项目方案", timezone_name="UTC")

    assert parsed.intent == "create_task"
    assert parsed.summary == "整理项目方案"
    assert parsed.bucket == "someday"
    assert parsed.due_at is not None
    assert parsed.time_expression == "下周"
    assert parsed.needs_confirmation is True
    assert parsed.questions == ["你说的下周，是下周一，还是下周内任意时间？"]
    assert parsed.error_code == "ambiguous_time"


def test_capture_api_returns_questions_for_ambiguous_time(test_context: tuple[TestClient, sessionmaker]) -> None:
    client, _ = test_context

    response = client.post(
        "/api/assistant/capture",
        json={
            "input": "晚点提醒我看下邮箱",
            "context": {"timezone": "UTC", "actor": "tester"},
            "apply": False,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["draft"]["needs_confirmation"] is True
    assert payload["draft"]["questions"] == ["你希望我什么时候提醒你？给我一个更具体的时间吧。"]
    assert payload["draft"]["error_code"] == "needs_confirmation"
    assert payload["questions"] == payload["draft"]["questions"]
    assert payload["error_code"] == payload["draft"]["error_code"]


def test_capture_api_apply_true_does_not_persist_when_confirmation_is_required(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context

    response = client.post(
        "/api/assistant/capture",
        json={
            "input": "晚点提醒我看下邮箱",
            "context": {"timezone": "UTC", "actor": "tester", "source": "chat_ai", "source_ref": "msg-1"},
            "apply": True,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["applied"] is True
    assert payload["created"] is None
    assert payload["draft"]["needs_confirmation"] is True
    assert payload["draft"]["error_code"] == "needs_confirmation"

    with TestingSessionLocal() as db:
        tasks = list(db.scalars(select(Task)).all())
        assert tasks == []
        logs = list(db.scalars(select(OperationLog).where(OperationLog.operation_type == "assistant_capture")).all())
        assert logs == []


def test_capture_api_apply_true_marks_created_task_as_sync_pending(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context

    response = client.post(
        "/api/assistant/capture",
        json={
            "input": "明晚8点提醒我给张三发合同",
            "context": {"timezone": "Asia/Shanghai", "actor": "tester", "source": "chat_ai", "source_ref": "msg-2"},
            "apply": True,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["created"] is not None
    assert payload["draft"]["intent"] == "create_task"
    assert payload["draft"]["summary"] == "给张三发合同"
    assert payload["draft"]["bucket"] == "next"
    assert payload["draft"]["needs_confirmation"] is False
    task_id = payload["created"]["task_id"]

    with TestingSessionLocal() as db:
        task = db.scalar(select(Task).where(Task.id == UUID(task_id)))
        assert task is not None
        assert task.sync_pending is True
        assert task.sync_change_id == 1
        assert task.title == "给张三发合同"
        assert task.bucket == "next"
        assert task.source == "chat_ai"
        assert task.source_ref == "msg-2"


def test_capture_api_accepts_legacy_text_and_dry_run_contract(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context

    response = client.post(
        "/api/assistant/capture",
        json={
            "text": "明晚8点提醒我给张三发合同",
            "context": {"timezone": "Asia/Shanghai", "actor": "tester", "source": "chat_ai", "source_ref": "legacy-msg"},
            "dry_run": True,
        },
    )

    assert response.status_code == 200
    payload = response.json()
    assert payload["applied"] is False
    assert payload["created"] is None
    assert payload["draft"]["intent"] == "create_task"
    assert payload["draft"]["summary"] == "给张三发合同"
    assert payload["draft"]["bucket"] == "next"
    assert payload["draft"]["needs_confirmation"] is False

    with TestingSessionLocal() as db:
        tasks = list(db.scalars(select(Task)).all())
        assert tasks == []
