from fastapi import Depends
from sqlalchemy.orm import Session

from app.db.session import get_db

DBSession = Depends(get_db)
