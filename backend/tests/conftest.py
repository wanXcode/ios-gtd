from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.session import get_db
from app.main import app as fastapi_app


@pytest.fixture()
def test_context() -> Generator[tuple[TestClient, sessionmaker], None, None]:
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

    def override_get_db() -> Generator[Session, None, None]:
        db = testing_session_local()
        try:
            yield db
        finally:
            db.close()

    previous_override = fastapi_app.dependency_overrides.get(get_db)
    fastapi_app.dependency_overrides[get_db] = override_get_db

    with TestClient(fastapi_app) as client:
        yield client, testing_session_local

    if previous_override is None:
        fastapi_app.dependency_overrides.pop(get_db, None)
    else:
        fastapi_app.dependency_overrides[get_db] = previous_override

    engine.dispose()
