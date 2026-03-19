from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from app.schemas.common import ORMModel


class ProjectCreate(BaseModel):
    name: str
    description: str | None = None


class ProjectRead(ORMModel):
    id: UUID
    name: str
    description: str | None = None
    status: str
    created_at: datetime
    updated_at: datetime
