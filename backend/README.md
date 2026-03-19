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
- placeholder sync endpoints:
  - `POST /api/sync/apple/pull`
  - `POST /api/sync/apple/push`
  - `POST /api/sync/apple/ack`
- Alembic migration for initial schema
- local test coverage for the main task lifecycle, assistant endpoints, and sync placeholders

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

## Sync placeholder contract

These endpoints are intentionally minimal but runnable, testable, and stable enough for bridge-side contract work.

- `POST /api/sync/apple/pull`: currently returns placeholder pull payload
- `POST /api/sync/apple/push`: returns task snapshots for requested IDs
- `POST /api/sync/apple/ack`: records/updates Apple mapping acknowledgements

They also create `sync_runs` records so test deployments can inspect sync activity.

## Testing

```bash
pytest
```

Covered right now:

- health check
- create / complete / reopen / soft delete lifecycle
- batch update
- operation log writes
- sync placeholder smoke path

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

- sync endpoints are still placeholder contract endpoints, not real EventKit sync logic
- no auth / multi-user separation yet
- no pagination yet on task listing
- no dedicated operation log query API yet
- no production infra manifests yet
