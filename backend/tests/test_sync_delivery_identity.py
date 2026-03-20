from uuid import UUID

from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import sessionmaker

from app.models.apple_mapping import AppleReminderMapping
from app.models.sync_bridge_state import SyncBridgeState
from app.models.sync_delivery import SyncDelivery
from app.models.task import Task


def _push_single(client: TestClient, bridge_id: str, task_id: str) -> dict:
    push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": bridge_id, "cursor": "0", "limit": 10, "tasks": []},
    )
    assert push.status_code == 200, push.text
    return next(entry for entry in push.json()["items"] if entry["task_id"] == task_id)


def test_push_emits_delivery_identity_and_ack_can_bind_by_delivery_id(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context
    created = client.post("/api/tasks", json={"title": "Delivery id task", "last_modified_by": "tester"}).json()

    item = _push_single(client, "bridge-delivery-id", created["id"])
    assert item["delivery_id"]
    assert item["delivery_seq"] == 1

    ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-delivery-id",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-delivery-id-1",
                    "version": item["version"],
                    "delivery_id": item["delivery_id"],
                    "status": "success",
                }
            ],
        },
    )
    assert ack.status_code == 200, ack.text
    payload = ack.json()
    assert payload["success"] == 1
    assert payload["checkpoint"]["last_acked_delivery_seq"] == item["delivery_seq"]

    replay = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-delivery-id", "cursor": str(item["change_id"]), "limit": 10, "tasks": []},
    )
    assert replay.status_code == 200, replay.text
    assert all(entry["task_id"] != created["id"] for entry in replay.json()["items"])

    with TestingSessionLocal() as db:
        delivery = db.scalar(
            select(SyncDelivery).where(
                SyncDelivery.bridge_id == "bridge-delivery-id",
                SyncDelivery.task_id == created["id"],
            )
        )
        state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == "bridge-delivery-id"))
        assert delivery is not None
        assert str(delivery.delivery_id) == item["delivery_id"]
        assert delivery.delivery_seq == item["delivery_seq"]
        assert delivery.status == "acknowledged"
        assert state.last_acked_delivery_seq == item["delivery_seq"]


def test_delivery_id_compatibility_bridge_survives_new_change_until_bridge_adopts_delivery_identity(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context
    created = client.post("/api/tasks", json={"title": "Compat bridge", "last_modified_by": "tester"}).json()

    first_item = _push_single(client, "bridge-supersede", created["id"])

    updated = client.patch(
        f"/api/tasks/{created['id']}",
        json={"title": "Compat bridge v2", "last_modified_by": "tester"},
    )
    assert updated.status_code == 200, updated.text

    second_push = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-supersede", "cursor": str(first_item["change_id"]), "limit": 10, "tasks": []},
    )
    assert second_push.status_code == 200, second_push.text
    second_item = next(entry for entry in second_push.json()["items"] if entry["task_id"] == created["id"])
    assert second_item["delivery_seq"] == first_item["delivery_seq"]
    assert second_item["delivery_id"] == first_item["delivery_id"]
    assert second_item["change_id"] > first_item["change_id"]

    compat_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-supersede",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-supersede-1",
                    "version": second_item["version"],
                    "delivery_id": first_item["delivery_id"],
                    "status": "success",
                }
            ],
        },
    )
    assert compat_ack.status_code == 200, compat_ack.text

    with TestingSessionLocal() as db:
        deliveries = list(
            db.scalars(
                select(SyncDelivery)
                .where(
                    SyncDelivery.bridge_id == "bridge-supersede",
                    SyncDelivery.task_id == created["id"],
                )
                .order_by(SyncDelivery.delivery_seq.asc())
            ).all()
        )
        assert len(deliveries) == 2
        acked = next(delivery for delivery in deliveries if delivery.delivery_seq == first_item["delivery_seq"])
        pending = next(delivery for delivery in deliveries if delivery.delivery_seq != first_item["delivery_seq"])
        assert acked.status == "acknowledged"
        assert acked.task_version == second_item["version"]
        assert pending.status == "pending"
        state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == "bridge-supersede"))
        assert state.last_acked_delivery_seq == first_item["delivery_seq"]

    replay = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-supersede", "cursor": str(second_item["change_id"]), "limit": 10, "tasks": []},
    )
    assert replay.status_code == 200, replay.text
    replay_item = next(entry for entry in replay.json()["items"] if entry["task_id"] == created["id"])
    assert replay_item["delivery_seq"] == pending.delivery_seq
    assert replay_item["delivery_id"] == str(pending.delivery_id)


def test_failed_and_conflict_acks_update_delivery_seq_checkpoint_and_replay_same_delivery(
    test_context: tuple[TestClient, sessionmaker],
) -> None:
    client, TestingSessionLocal = test_context
    created = client.post("/api/tasks", json={"title": "Replay semantics", "last_modified_by": "tester"}).json()

    item = _push_single(client, "bridge-delivery-replay", created["id"])

    failed_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-delivery-replay",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-delivery-replay-1",
                    "version": item["version"],
                    "delivery_id": item["delivery_id"],
                    "delivery_seq": item["delivery_seq"],
                    "status": "failed",
                    "retryable": True,
                    "error_code": "timeout",
                }
            ],
        },
    )
    assert failed_ack.status_code == 200, failed_ack.text
    assert failed_ack.json()["checkpoint"]["last_failed_delivery_seq"] == item["delivery_seq"]

    replay = client.post(
        "/api/sync/apple/push",
        json={"bridge_id": "bridge-delivery-replay", "cursor": str(item["change_id"]), "limit": 10, "tasks": []},
    )
    assert replay.status_code == 200, replay.text
    replay_item = next(entry for entry in replay.json()["items"] if entry["task_id"] == created["id"])
    assert replay_item["delivery_id"] == item["delivery_id"]
    assert replay_item["delivery_seq"] == item["delivery_seq"]

    conflict_ack = client.post(
        "/api/sync/apple/ack",
        json={
            "bridge_id": "bridge-delivery-replay",
            "acks": [
                {
                    "task_id": created["id"],
                    "remote_id": "apple-delivery-replay-1",
                    "version": replay_item["version"],
                    "delivery_id": replay_item["delivery_id"],
                    "status": "conflict",
                    "error_code": "remote_conflict",
                }
            ],
        },
    )
    assert conflict_ack.status_code == 200, conflict_ack.text
    assert conflict_ack.json()["conflict"] == 1
    assert conflict_ack.json()["checkpoint"]["last_failed_delivery_seq"] == item["delivery_seq"]

    with TestingSessionLocal() as db:
        delivery = db.scalar(
            select(SyncDelivery).where(
                SyncDelivery.bridge_id == "bridge-delivery-replay",
                SyncDelivery.task_id == created["id"],
                SyncDelivery.delivery_seq == item["delivery_seq"],
            )
        )
        mapping = db.scalar(select(AppleReminderMapping).where(AppleReminderMapping.task_id == UUID(created["id"])))
        task = db.scalar(select(Task).where(Task.id == UUID(created["id"])))
        state = db.scalar(select(SyncBridgeState).where(SyncBridgeState.bridge_id == "bridge-delivery-replay"))
        assert delivery is not None
        assert delivery.attempt_count == 2
        assert delivery.status == "conflict"
        assert mapping.last_delivery_status == "conflict"
        assert task.sync_pending is True
        assert state.last_failed_delivery_seq == item["delivery_seq"]
