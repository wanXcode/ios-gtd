# Roadmap

## Phase 1 - Backend Core

- [x] FastAPI app skeleton
- [x] Config management
- [x] SQLAlchemy models
- [x] Alembic initial migration
- [x] Health / tasks / projects / tags API
- [x] SQLite local dev compatibility
- [x] Basic README and API docs

## Phase 2 - AI-facing helpers

- [ ] capture / today / waiting endpoints
- [ ] inbox organize helpers
- [ ] batch task update endpoint

## Phase 3 - Apple Reminders bridge MVP

- [ ] sync pull API
- [ ] sync push API
- [ ] sync ack API
- [ ] bridge state model and retry policy

## Phase 4 - Reliability

- [ ] auth
- [ ] operation logging wiring
- [ ] sync conflict logging
- [ ] tests for CRUD + filtering + completion flow

## Phase 5 - Deployment

- [ ] Dockerfile / compose
- [ ] Postgres production config
- [ ] reverse proxy notes
