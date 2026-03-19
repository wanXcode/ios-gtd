from datetime import datetime
from uuid import UUID

from pydantic import BaseModel

from app.schemas.common import ORMModel


class TagCreate(BaseModel):
    name: str
    color: str | None = None


class TagRead(ORMModel):
    id: UUID
    name: str
    color: str | None = None
    created_at: datetime
