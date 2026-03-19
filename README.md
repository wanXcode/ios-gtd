# ios-gtd

基于 `docs/PRD.md` 与 `docs/TECH_SPEC.md` 的第一阶段实现，目前已落下一个可运行的 MVP 后端骨架。

## 当前范围

已完成：

- `backend/` FastAPI 项目结构
- 配置管理（`pydantic-settings`）
- SQLAlchemy 2.x 模型
- Alembic 初始迁移
- SQLite 开发兼容，PostgreSQL 作为生产默认取向
- 基础 API：
  - `GET /api/health`
  - `GET/POST /api/projects`
  - `GET/POST /api/tags`
  - `GET/POST /api/tasks`
  - `GET/PATCH/DELETE /api/tasks/{id}`
  - `POST /api/tasks/{id}/complete`
- 最小测试样例

## 目录

```text
ios-gtd/
  backend/
    app/
    alembic/
    tests/
  docs/
    PRD.md
    TECH_SPEC.md
    API_SPEC.md
    ROADMAP.md
```

## 本地启动

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload
```

当前实现支持 Python 3.11+。

访问：

- Swagger UI: http://127.0.0.1:8000/docs
- Health: http://127.0.0.1:8000/api/health

## 数据库策略

开发环境默认使用 SQLite：

```env
DATABASE_URL=sqlite:///./gtd.db
```

生产建议切换 PostgreSQL：

```env
DATABASE_URL=postgresql+psycopg://user:password@host:5432/ios_gtd
```

## 下一步建议

- 补任务批量更新 / reopen / done filtering
- 增加 operation_logs 自动记录
- 落地 Apple sync pull/push/ack API
- 增加 assistant 高层接口
- 引入 auth、structured logging、settings 分层
