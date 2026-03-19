# ios-gtd

一个以 GTD 主库为核心、以 Apple Reminders 为原生入口之一、以 AI 对话为整理入口的个人任务系统。

当前仓库已经有第一阶段的后端 MVP 骨架，同时补齐了接口设计与路线图文档，方便继续直接开发。

## 项目概览

目标不是再做一个普通 todo app，而是先跑通这条链路：

- 后端维护统一任务主库
- Apple Reminders 继续作为日常原生入口
- AI 可以直接查询、整理、批量修改任务
- 后端与 Apple Reminders 最终实现双向同步

当前技术路线保持与 `docs/PRD.md`、`docs/TECH_SPEC.md` 一致：

- Backend：FastAPI + SQLAlchemy + Alembic
- DB：开发环境 SQLite，生产建议 PostgreSQL
- Sync Bridge：后续采用 macOS + Swift + EventKit
- AI Layer：通过后端 API 承接自然语言任务操作

## 当前仓库状态

已落地：

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

已补齐文档：

- `docs/API_SPEC.md`：接口规范，覆盖 tasks / projects / tags / sync / assistant
- `docs/ROADMAP.md`：MVP 里程碑、优先级、阶段任务、风险

注意：

- 当前代码实现的接口能力，以 Swagger 与 `backend/app/api/routes/` 为准
- `docs/API_SPEC.md` 中已明确区分“已实现”和“规划中”接口，便于继续增量开发

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

## 文档导航

- 产品目标与边界：`docs/PRD.md`
- 架构、模型与技术路线：`docs/TECH_SPEC.md`
- 接口设计与请求/响应约定：`docs/API_SPEC.md`
- 开发路线图与优先级：`docs/ROADMAP.md`

如果准备继续写代码，建议阅读顺序：

1. `docs/PRD.md`
2. `docs/TECH_SPEC.md`
3. `docs/API_SPEC.md`
4. `docs/ROADMAP.md`

## 本地启动

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
cp .env.example .env
alembic upgrade head
uvicorn app.main:app --reload
```

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

## 推荐下一步

按当前文档设计，建议优先继续做：

1. `POST /tasks/{id}/reopen`
2. `POST /tasks/batch-update`
3. `operation_logs` 自动写入
4. Apple sync 的 run / pull / push / ack 主链路
5. assistant 的 capture / today / inbox-organize

这几项补完后，项目会从“有骨架”进入“可跑 GTD 闭环”的阶段。