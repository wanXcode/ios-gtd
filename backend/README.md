# ios-gtd backend

FastAPI + SQLAlchemy + Alembic backend for the iOS GTD MVP.

## Quick start

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload
```

Python 3.11+ is supported for the current MVP.

Open http://127.0.0.1:8000/docs

## Environment

- `DATABASE_URL`: defaults to local SQLite for dev
- `APP_ENV`: local / dev / prod
- `APP_HOST`
- `APP_PORT`

## Database

Development defaults to SQLite:

```env
DATABASE_URL=sqlite:///./gtd.db
```

Production target:

```env
DATABASE_URL=postgresql+psycopg://user:password@localhost:5432/ios_gtd
```
