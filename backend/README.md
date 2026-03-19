# ios-gtd backend

FastAPI + SQLAlchemy + Alembic backend for the iOS GTD MVP. This version is aimed at a deployable test build: it can migrate, boot, expose usable task/project/tag APIs, and includes a minimal sync contract for Apple bridge integration.

## What is implemented

- health / projects / tags / tasks API
- task reopen API: `POST /api/tasks/{id}/reopen`
- task batch update API: `POST /api/tasks/batch-update`
- assistant-oriented higher-level API:
  - `POST /api/assistant/capture`
  - `GET /api/assistant/views/today`
  - `GET /api/assistant/views/waiting`
- soft-delete-first task deletion strategy
- operation log recording for task create/update/complete/reopen/delete/batch-update/assistant_capture
- Apple sync bridge endpoints:
  - `POST /api/sync/apple/pull`
  - `POST /api/sync/apple/push`
  - `POST /api/sync/apple/ack`
  - `GET /api/sync/apple/state/{bridge_id}`
- sync-oriented task / mapping / bridge-state fields:
  - `tasks.is_all_day_due`
  - `tasks.sync_change_id`
  - `tasks.sync_pending`
  - `tasks.sync_last_pushed_at`
  - `apple_reminder_mappings.pending_operation`
  - `apple_reminder_mappings.last_push_change_id / last_acked_change_id`
  - `apple_reminder_mappings.last_ack_status / last_delivery_status / last_delivery_attempt_count / last_failed_change_id`
  - `sync_bridge_states.backend_cursor / last_pull_cursor / last_push_cursor / last_acked_change_id / last_failed_change_id`
  - `sync_deliveries` minimal ledger for bridge delivery / retry / failure inspection
- Alembic migrations for initial schema + sync bridge fields + per-bridge checkpoint state + delivery ledger
- local test coverage for task lifecycle + sync pull/push/ack/idempotency checkpoint flow

## Quick start

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

Open:

- Swagger: http://127.0.0.1:8000/docs
- Health: http://127.0.0.1:8000/api/health

## Environment variables

Copy `.env.example` to `.env` and adjust as needed.

```env
APP_NAME=ios-gtd-backend
APP_ENV=local
APP_HOST=127.0.0.1
APP_PORT=8000
DATABASE_URL=sqlite:///./gtd.db
```

Current code defaults:

- `APP_NAME`: service name shown in docs/health
- `APP_ENV`: `local`, `dev`, `prod`
- `APP_HOST`: bind host
- `APP_PORT`: bind port
- `DATABASE_URL`: SQLite for local dev, PostgreSQL recommended for deployment

Recommended PostgreSQL URL:

```env
DATABASE_URL=postgresql+psycopg://user:password@host:5432/ios_gtd
```

## Database and migration

Run migrations:

```bash
alembic upgrade head
```

Create a new migration after schema change:

```bash
alembic revision --autogenerate -m "describe change"
```

Rollback one step if needed:

```bash
alembic downgrade -1
```

## Task API notes

### Delete strategy

Tasks are soft-deleted by default.

- `DELETE /api/tasks/{id}` sets `deleted_at`, marks status as `deleted`, and writes an operation log.
- `GET /api/tasks` hides soft-deleted rows by default.
- `GET /api/tasks?include_deleted=true` includes soft-deleted rows.

This keeps sync/history safer for test deployments.

### Main task routes

- `GET /api/tasks`
- `POST /api/tasks`
- `GET /api/tasks/{id}`
- `PATCH /api/tasks/{id}`
- `DELETE /api/tasks/{id}`
- `POST /api/tasks/{id}/complete`
- `POST /api/tasks/{id}/reopen`
- `POST /api/tasks/batch-update`

## Assistant higher-level routes

These routes are meant for AI / chat orchestration so the model does not have to reconstruct common GTD behaviors from raw CRUD every time.

- `POST /api/assistant/capture`
  - turns natural language into a minimal task capture
  - supports `dry_run=true` for parse-only behavior
  - current parser is intentionally heuristic and conservative
- `GET /api/assistant/views/today`
  - returns active tasks due today
  - optionally includes overdue tasks
  - excludes `someday` and deleted tasks
- `GET /api/assistant/views/waiting`
  - returns active tasks in the `waiting` bucket

Important contract note: `POST /api/assistant/capture` expects `input`, not `text`.

Example capture request:

```json
{
  "input": "明天提醒我发合同",
  "context": {
    "timezone": "Asia/Shanghai",
    "source": "chat",
    "source_ref": "msg_123",
    "actor": "chat"
  },
  "dry_run": false
}
```

## Sync bridge contract

These endpoints are now meant for real bridge bring-up, not just a placeholder smoke path.

- `POST /api/sync/apple/pull`
  - accepts remote `changes[]` from Apple side
  - supports `upsert` and `delete`
  - creates/updates local tasks and Apple mappings
  - marks sync conflicts conservatively instead of overwriting blindly
  - persists per-bridge checkpoint state and returns a `checkpoint` snapshot in response
- `POST /api/sync/apple/push`
  - returns local tasks that still have `sync_pending=true`
  - includes `change_id`, `operation`, mapping info, and task snapshot
  - supports bridge-side `cursor` filtering to avoid replaying already-seen changes in the same bridge
  - skips already-acked `last_push_change_id` payloads to reduce duplicate write-back risk
- `POST /api/sync/apple/ack`
  - now supports explicit `change_id` on each ack item so bridge ack semantics can bind to a specific delivered change
  - updates mapping after bridge write-back
  - clears pending state on success
  - preserves pending state on failure
  - marks mapping as conflict on conflict ack
  - ignores stale acks when `change_id` is already acked or version is older than the mapping's last synced version
  - rejects impossible future ack versions and unknown explicit `change_id` values with HTTP 409
  - updates `sync_deliveries` ledger so retry / failure history is inspectable per `bridge_id + task_id + change_id`
- `GET /api/sync/apple/state/{bridge_id}`
  - returns the backend's persisted per-bridge checkpoint / cursor snapshot
  - also exposes `pending_delivery_count` plus `recent_deliveries[]` summary for bridge cold-start inspection and retry/debug UI

All sync endpoints also create `sync_runs` rows so test deployments can inspect sync activity.

## Testing

```bash
pytest
```

Current local regression baseline:

- `12 passed` on project test suite
- tests now run with per-test isolated DB/client fixtures, so full-suite results are stable and suitable as pre-E2E guardrail

Covered right now:

- health check
- create / complete / reopen / soft delete lifecycle
- batch update
- operation log writes
- sync pull / push / ack flow
- per-bridge checkpoint persistence
- stale ack ignore + push cursor dedupe behavior
- explicit ack `change_id` validation + retry ledger behavior

## Docker

Build and run backend only:

```bash
cd backend
docker build -t ios-gtd-backend .
docker run --rm -p 8000:8000 -e DATABASE_URL=sqlite:///./gtd.db ios-gtd-backend
```

Or from repo root:

```bash
docker compose -f docker-compose.dev.yml up --build
```

## Current known gaps

- backend now persists per-bridge checkpoint state, but bridge identity still has no auth binding / device credential model
- backend now keeps a minimal delivery ledger, but retry scheduling / backoff policy is still mostly bridge-owned
- no pagination yet on task listing
- no dedicated operation log query API yet
- no production infra manifests yet
