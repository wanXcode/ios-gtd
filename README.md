# ios-gtd

一个以 GTD 主库为核心、以 Apple Reminders 为原生入口之一、以 AI 对话为整理入口的个人任务系统。

这版仓库已经从“后端骨架”推进到“可部署测试版”附近：后端可迁移、可启动、可测试，tasks 主链路更完整，也补上了最小可用的 Apple sync API 骨架，适合开始部署测试。

## 当前状态

后端已具备：

- FastAPI + SQLAlchemy + Alembic 基础工程
- SQLite 本地开发可用，PostgreSQL 可作为部署目标
- tasks / projects / tags 可运行 API
- tasks 增强：
  - `POST /api/tasks/{id}/reopen`
  - `POST /api/tasks/batch-update`
  - 软删除优先
  - `operation_logs` 已接入关键任务变更流程
- Apple sync 联调链路：
  - `POST /api/sync/apple/pull`：接收 Bridge 提交的 Apple 增量变更并落库
  - `POST /api/sync/apple/push`：返回待回写到 Apple 的本地任务变更
  - `POST /api/sync/apple/ack`：Bridge 成功/失败回执，更新 mapping 与 pending 状态
  - `GET /api/sync/apple/state/{bridge_id}`：读取后端持久化的 per-bridge checkpoint / cursor 状态
- sync 语义补强：
  - `Task.sync_change_id` / `sync_pending` / `sync_last_pushed_at`
  - `Task.is_all_day_due`
  - `AppleReminderMapping.pending_operation` / `last_push_change_id` / `last_ack_status`
  - `SyncBridgeState.backend_cursor / last_pull_cursor / last_push_cursor / last_acked_change_id`
- 本地测试与 smoke test
- Dockerfile + `docker-compose.dev.yml`

## 仓库结构

```text
ios-gtd/
  backend/
    app/
    alembic/
    tests/
    Dockerfile
  docs/
    PRD.md
    TECH_SPEC.md
    API_SPEC.md
    ROADMAP.md
  mac-sync-bridge/
  docker-compose.dev.yml
```

## 快速本地启动

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

访问：

- Swagger UI: http://127.0.0.1:8000/docs
- Health: http://127.0.0.1:8000/api/health

## 用 Docker 跑开发版

仓库根目录执行：

```bash
docker compose -f docker-compose.dev.yml up --build
```

## 环境变量

`backend/.env.example`：

```env
APP_NAME=ios-gtd-backend
APP_ENV=local
APP_HOST=127.0.0.1
APP_PORT=8000
DATABASE_URL=sqlite:///./gtd.db
```

生产建议使用 PostgreSQL：

```env
DATABASE_URL=postgresql+psycopg://user:password@host:5432/ios_gtd
```

## 迁移与测试

迁移：

```bash
cd backend
alembic upgrade head
```

测试：

```bash
cd backend
pytest
```

## 部署测试建议

如果是第一次把它部署到测试环境，建议按这个顺序：

1. 准备 Python 3.11+ 或 Docker 环境
2. 配置 `DATABASE_URL`（测试期可先 SQLite，建议尽快切 PostgreSQL）
3. 执行 `alembic upgrade head`
4. 启动 `uvicorn app.main:app`
5. 先验证：
   - `GET /api/health`
   - 创建 task
   - complete / reopen / delete
   - `POST /api/tasks/batch-update`
   - `POST /api/sync/apple/pull|push|ack`

## 已知缺口

当前已经适合“部署测试”，但还不是完整生产版：

- Apple sync 已经不是纯占位：已能处理 pull / push / ack 的基本闭环，并持久化 per-bridge checkpoint；但仍未接入真实 EventKit 与长期冲突处理
- 没有鉴权、多用户隔离、权限控制
- 没有真正的后台任务/队列处理
- 没有更细的观测、日志查询接口、运维脚本
- 删除目前采用软删除优先；真正的数据清理策略后续还要再定

## 文档导航

- 产品目标与边界：`docs/PRD.md`
- 架构、模型与技术路线：`docs/TECH_SPEC.md`
- 接口设计与请求/响应约定：`docs/API_SPEC.md`
- 开发路线图与优先级：`docs/ROADMAP.md`
- Bridge 设计与当前收口状态：`docs/SYNC_BRIDGE_SPEC.md`
- Bridge 真机编译前准备：`docs/BRIDGE_COMPILE_PREP.md`
- Bridge 手工 E2E 跑通说明：`docs/BRIDGE_E2E_MANUAL.md`
- 后端部署与运行：`backend/README.md`
- macOS bridge 运行说明：`mac-sync-bridge/README.md`
