#!/usr/bin/env python3
"""One-off SQLite schema repair for sync bridge tables/columns.

Safe to run multiple times. It only adds missing columns/tables/indexes needed by
20260319_0002/0003/0004 and current sync routes/models.
"""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path


TASKS_REQUIRED = [
    ("is_all_day_due", "ALTER TABLE tasks ADD COLUMN is_all_day_due BOOLEAN NOT NULL DEFAULT 0"),
    ("sync_change_id", "ALTER TABLE tasks ADD COLUMN sync_change_id INTEGER NOT NULL DEFAULT 1"),
    ("sync_pending", "ALTER TABLE tasks ADD COLUMN sync_pending BOOLEAN NOT NULL DEFAULT 1"),
    ("sync_last_pushed_at", "ALTER TABLE tasks ADD COLUMN sync_last_pushed_at DATETIME"),
]

MAPPINGS_REQUIRED = [
    ("pending_operation", "ALTER TABLE apple_reminder_mappings ADD COLUMN pending_operation VARCHAR(32)"),
    ("last_push_change_id", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_push_change_id INTEGER"),
    ("bridge_updated_at", "ALTER TABLE apple_reminder_mappings ADD COLUMN bridge_updated_at DATETIME"),
    ("last_ack_status", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_ack_status VARCHAR(32)"),
    ("last_error_code", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_error_code VARCHAR(64)"),
    ("last_error_message", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_error_message TEXT"),
    ("is_deleted_on_apple", "ALTER TABLE apple_reminder_mappings ADD COLUMN is_deleted_on_apple BOOLEAN NOT NULL DEFAULT 0"),
    ("last_acked_change_id", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_acked_change_id INTEGER"),
    ("last_delivery_status", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_delivery_status VARCHAR(32)"),
    ("last_delivery_attempt_count", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_delivery_attempt_count INTEGER"),
    ("last_failed_change_id", "ALTER TABLE apple_reminder_mappings ADD COLUMN last_failed_change_id INTEGER"),
]

SYNC_BRIDGE_STATES_SQL = """
CREATE TABLE IF NOT EXISTS sync_bridge_states (
    id CHAR(32) NOT NULL PRIMARY KEY,
    bridge_id VARCHAR(255) NOT NULL,
    backend_cursor TEXT,
    last_pull_cursor TEXT,
    last_push_cursor TEXT,
    last_acked_change_id INTEGER,
    last_seen_change_id INTEGER,
    last_pull_started_at DATETIME,
    last_pull_succeeded_at DATETIME,
    last_push_started_at DATETIME,
    last_push_succeeded_at DATETIME,
    last_ack_started_at DATETIME,
    last_ack_succeeded_at DATETIME,
    last_error_code VARCHAR(64),
    last_error_message TEXT,
    metadata JSON,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_failed_change_id INTEGER
)
""".strip()

SYNC_DELIVERIES_SQL = """
CREATE TABLE IF NOT EXISTS sync_deliveries (
    id CHAR(32) NOT NULL PRIMARY KEY,
    bridge_id VARCHAR(255) NOT NULL,
    task_id VARCHAR(36) NOT NULL,
    change_id INTEGER NOT NULL,
    task_version INTEGER NOT NULL,
    operation VARCHAR(32) NOT NULL,
    status VARCHAR(32) NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 1,
    retryable BOOLEAN NOT NULL DEFAULT 0,
    remote_id TEXT,
    last_error_code VARCHAR(64),
    last_error_message TEXT,
    first_pushed_at DATETIME,
    last_pushed_at DATETIME,
    acked_at DATETIME,
    failed_at DATETIME,
    metadata JSON,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
)
""".strip()

SYNC_BRIDGE_EXTRA = [
    ("last_failed_change_id", "ALTER TABLE sync_bridge_states ADD COLUMN last_failed_change_id INTEGER"),
]

UNIQUE_INDEXES = [
    ("uq_sync_bridge_state_bridge_id", "CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_bridge_state_bridge_id ON sync_bridge_states (bridge_id)"),
    ("uq_sync_delivery_bridge_task_change", "CREATE UNIQUE INDEX IF NOT EXISTS uq_sync_delivery_bridge_task_change ON sync_deliveries (bridge_id, task_id, change_id)"),
]


def columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def table_exists(conn: sqlite3.Connection, table: str) -> bool:
    row = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
    return row is not None


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} /path/to/gtd.db", file=sys.stderr)
        return 2

    db_path = Path(sys.argv[1])
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys=OFF")
    changes: list[str] = []
    try:
        if table_exists(conn, "tasks"):
            existing = columns(conn, "tasks")
            for name, sql in TASKS_REQUIRED:
                if name not in existing:
                    conn.execute(sql)
                    changes.append(f"tasks.{name}")
        if table_exists(conn, "apple_reminder_mappings"):
            existing = columns(conn, "apple_reminder_mappings")
            for name, sql in MAPPINGS_REQUIRED:
                if name not in existing:
                    conn.execute(sql)
                    changes.append(f"apple_reminder_mappings.{name}")

        if not table_exists(conn, "sync_bridge_states"):
            conn.execute(SYNC_BRIDGE_STATES_SQL)
            changes.append("table sync_bridge_states")
        else:
            existing = columns(conn, "sync_bridge_states")
            for name, sql in SYNC_BRIDGE_EXTRA:
                if name not in existing:
                    conn.execute(sql)
                    changes.append(f"sync_bridge_states.{name}")

        if not table_exists(conn, "sync_deliveries"):
            conn.execute(SYNC_DELIVERIES_SQL)
            changes.append("table sync_deliveries")

        for label, sql in UNIQUE_INDEXES:
            conn.execute(sql)
            changes.append(f"index {label}")

        conn.commit()
        print("OK")
        if changes:
            for item in changes:
                print(f"APPLIED {item}")
        else:
            print("NO_CHANGES")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
