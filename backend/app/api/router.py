from fastapi import APIRouter

from app.api.routes import assistant, health, projects, sync, tags, tasks

api_router = APIRouter()
api_router.include_router(health.router, tags=["health"])
api_router.include_router(tasks.router, prefix="/tasks", tags=["tasks"])
api_router.include_router(projects.router, prefix="/projects", tags=["projects"])
api_router.include_router(tags.router, prefix="/tags", tags=["tags"])
api_router.include_router(sync.router, prefix="/sync", tags=["sync"])
api_router.include_router(assistant.router, prefix="/assistant", tags=["assistant"])
