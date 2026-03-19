from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import sessionmaker

from app.models.apple_mapping import AppleReminderMapping
from app.models.sync_bridge_state import SyncBridgeState
from app.models.sync_delivery import SyncDelivery
from app.models.task import Task


def test_ack_requires_known_delivery_when_change_id_is_explicit(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, _ = test_context
    created = client.post("/api/tasks", json={"title": "Ack contract", "last_modified_by": "tester"}).json()

    push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-ack-contract", "cursor": "0", "limit": 10, "tasks": []},
    )
    assert push.status_code == 200
    item = next(entry for entry in push.json()["items"] if entry["task_id"] == created["id"])

    missing = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-ack-contract",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-contract-1",
                    "version": item["version"],
                    "change_id": item["change_id"] + 99,
                    "status": "success",
                }
            ],
        },
    )
    assert missing.status_code == 409
    assert "change_id ahead" in missing.json()["detail"]



def test_retryable_failed_ack_keeps_delivery_ledger_and_requeues_task(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context
    created = client.post("/api/tasks", json={"title": "Retry me", "last_modified_by": "tester"}).json()

    first_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-retry", "cursor": "0", "limit": 10, "tasks": []},
    )
    assert first_push.status_code == 200
    item = next(entry for entry in first_push.json()["items"] if entry["task_id"] == created["id"])

    failed_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-retry",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-retry-1",
                    "version": item["version"],
                    "change_id": item["change_id"],
                    "status": "failed",
                    "retryable": True,
                    "error_code": "timeout",
                    "error_message": "bridge timeout",
                }
            ],
        },
    )
    assert failed_ack.status_code == 200
    failed_payload = failed_ack.json()
    assert failed_payload["failed"] == 1
    assert failed_payload["checkpoint"]["last_failed_change_id"] == item["change_id"]

    second_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-retry", "cursor": str(item["change_id"] - 1), "limit": 10, "tasks": []},
    )
    assert second_push.status_code == 200
    second_item = next(entry for entry in second_push.json()["items"] if entry["task_id"] == created["id"])
    assert second_item["change_id"] == item["change_id"]

    with TestingSessionLocal() as db:
        task = db.scalar(select(Task).where(Task.id == UUID(created["id"])))
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == UUID(created["id"])))
        delivery = db.scalar(
            select(SyncDelivery).where(
                SyncDelivery.bridge_id == "bridge-retry",
                SyncDelivery.task_id == created["id"],
                SyncDelivery.change_id == item["change_id"],
            )
        )
        state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == "bridge-retry"))
        assert task.sync_pending is True
        assert mapping.pending_operation == "upsert"
        assert mapping.last_delivery_status == "retryable_failed"
        assert mapping.last_failed_change_id == item["change_id"]
        assert mapping.last_delivery_attempt_count == 2
        assert delivery is not None
        assert delivery.status == "pending"
        assert delivery.attempt_count == 2
        assert delivery.last_error_code == "timeout"
        assert delivery.last_error_message == "bridge timeout"
        assert delivery.acked_at is None
        assert state.last_failed_change_id == item["change_id"]

    state_response = client.get("/api/sync/apple/state/bridge-retry")
    assert state_response.status_code == 200
    state_payload = state_response.json()
    assert state_payload["pending_delivery_count"] >= 1
    assert state_payload["recent_deliveries"][0]["task_id"] == created["id"]
    assert state_payload["recent_deliveries"][0]["change_id"] == item["change_id"]
    assert state_payload["recent_deliveries"][0]["status"] == "pending"
    assert state_payload["recent_deliveries"][0]["attempt_count"] == 2



def test_stale_ack_by_change_id_is_ignored_after_success(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, _ = test_context
    created = client.post("/api/tasks", json={"title": "Ack once", "last_modified_by": "tester"}).json()

    push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-stale-change", "cursor": "0", "limit": 10, "tasks": []},
    )
    item = next(entry for entry in push.json()["items"] if entry["task_id"] == created["id"])

    success_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-stale-change",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-stale-1",
                    "version": item["version"],
                    "change_id": item["change_id"],
                    "status": "success",
                }
            ],
        },
    )
    assert success_ack.status_code == 200

    stale_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-stale-change",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-stale-1",
                    "version": item["version"],
                    "change_id": item["change_id"],
                    "status": "success",
                }
            ],
        },
    )
    assert stale_ack.status_code == 200
    assert stale_ack.json()["acked"][0]["status"] == "stale_ignored"
