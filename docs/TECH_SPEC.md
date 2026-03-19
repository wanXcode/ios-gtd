# GTD 系统技术文档（Technical Spec）

## 1. 技术目标

本系统采用“自有后端 + Apple Reminders 同步桥 + AI 对话入口”的三层架构。

技术目标如下：

1. 构建稳定的线上任务主库
2. 支持 GTD 所需的基础任务语义
3. 支持与 Apple Reminders 的双向同步
4. 提供对话操作所需的任务 API
5. 允许未来扩展为 Web、CalDAV、统计、自动化等能力

---

## 2. 总体架构

```text
[iPhone Reminders] 
        ↕ iCloud
[Mac Reminders]
        ↕
[Mac Sync Bridge]
        ↕ HTTPS API
[GTD Backend]
        ↕
[AI Conversation Layer]
```

### 2.1 分层说明

#### A. GTD Backend
线上主系统，负责：
- 任务数据存储
- GTD 语义表达
- API 提供
- 操作日志
- 同步日志
- 冲突处理

#### B. Mac Sync Bridge
运行在 macOS 上的本地常驻程序，负责：
- 读取 Apple Reminders
- 写入 Apple Reminders
- 同步状态维护
- 增量同步
- 映射转换

#### C. AI Conversation Layer
通过调用 GTD Backend API 实现：
- 创建任务
- 查询任务
- 修改任务
- 批量整理任务
- GTD 分类与建议

---

## 3. 技术选型建议

## 3.1 后端
建议：
- Python 3.12+
- FastAPI
- SQLAlchemy / SQLModel
- PostgreSQL
- Alembic 迁移
- Pydantic 数据校验

原因：
- 开发效率高
- 适合 API 服务
- 适合自然语言任务整理逻辑扩展
- 便于后续接 AI 工作流

## 3.2 同步桥
建议：
- Swift
- EventKit
- macOS LaunchAgent
- 本地 SQLite / JSON 状态缓存

原因：
- 原生支持 Reminders
- 运行稳定
- 便于做常驻同步代理

## 3.3 部署
建议：
- Linux 服务器部署后端
- Nginx / Caddy 反代
- HTTPS
- JWT / Token 鉴权

---

## 4. 数据模型设计

## 4.1 tasks

```sql
tasks (
  id uuid primary key,
  title text not null,
  note text,
  status varchar(32) not null default 'active',
  bucket varchar(32) not null default 'inbox',
  priority integer,
  due_at timestamptz,
  remind_at timestamptz,
  completed_at timestamptz,
  deleted_at timestamptz,
  source varchar(32),
  source_ref text,
  project_id uuid null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  last_modified_by varchar(32) not null,
  version bigint not null default 1
)
```

说明：
- status：active / completed / archived / deleted
- bucket：inbox / next / waiting / someday / project / done
- version：乐观并发 / 同步辅助

## 4.2 projects

```sql
projects (
  id uuid primary key,
  name text not null,
  description text,
  status varchar(32) not null default 'active',
  created_at timestamptz not null,
  updated_at timestamptz not null
)
```

## 4.3 tags

```sql
tags (
  id uuid primary key,
  name text not null unique,
  color varchar(16),
  created_at timestamptz not null
)
```

## 4.4 task_tags

```sql
task_tags (
  task_id uuid not null,
  tag_id uuid not null,
  primary key (task_id, tag_id)
)
```

## 4.5 apple_reminder_mappings

```sql
apple_reminder_mappings (
  id uuid primary key,
  task_id uuid not null,
  apple_reminder_id text not null,
  apple_list_id text,
  apple_calendar_id text,
  last_synced_task_version bigint,
  last_seen_apple_modified_at timestamptz,
  sync_state varchar(32) not null default 'active',
  created_at timestamptz not null,
  updated_at timestamptz not null,
  unique (apple_reminder_id)
)
```

作用：
- 记录线上 task 与 Apple Reminder 的对应关系
- 支撑增量同步与回写

## 4.6 operation_logs

```sql
operation_logs (
  id uuid primary key,
  task_id uuid,
  operation_type varchar(32) not null,
  actor varchar(32) not null,
  source varchar(32) not null,
  payload jsonb,
  created_at timestamptz not null
)
```

actor 示例：
- user_chat
- apple_sync_bridge
- system

## 4.7 sync_runs

```sql
sync_runs (
  id uuid primary key,
  bridge_id text not null,
  started_at timestamptz not null,
  finished_at timestamptz,
  status varchar(32) not null,
  stats jsonb,
  error_message text
)
```

---

## 5. API 设计

## 5.1 任务接口

### POST /api/tasks
创建任务

请求体示例：
```json
{
  "title": "给客户回电话",
  "note": "讨论合同",
  "bucket": "inbox",
  "due_at": "2026-03-20T14:00:00+08:00",
  "last_modified_by": "chat"
}
```

### GET /api/tasks
查询任务，支持筛选参数：
- bucket
- status
- project_id
- due_before
- due_after
- updated_after
- q

### GET /api/tasks/{id}
获取任务详情

### PATCH /api/tasks/{id}
更新任务

### POST /api/tasks/{id}/complete
完成任务

### POST /api/tasks/{id}/reopen
重开任务

### POST /api/tasks/batch-update
批量更新任务

---

## 5.2 项目接口

- POST /api/projects
- GET /api/projects
- PATCH /api/projects/{id}

---

## 5.3 标签接口

- POST /api/tags
- GET /api/tags

---

## 5.4 同步桥接口

### POST /api/sync/apple/pull
由同步桥上传 Apple 侧变更

请求体示例：
```json
{
  "bridge_id": "macbook-pro-001",
  "changes": [
    {
      "apple_reminder_id": "xxx",
      "apple_list_id": "inbox-list-id",
      "title": "给客户回电话",
      "note": "讨论合同",
      "is_completed": false,
      "due_at": "2026-03-20T14:00:00+08:00",
      "modified_at": "2026-03-19T00:00:00Z"
    }
  ]
}
```

后端职责：
- 匹配 mapping
- 新建或更新 task
- 记录日志
- 返回处理结果

### POST /api/sync/apple/push
同步桥拉取后端待下发变更（请求体带 `bridge_id / cursor / tasks[] / limit`）

返回：
```json
{
  "changes": [
    {
      "task_id": "uuid",
      "apple_reminder_id": "xxx",
      "op": "update",
      "fields": {
        "title": "新的标题",
        "note": "新的备注",
        "due_at": "2026-03-21T09:00:00+08:00",
        "is_completed": false,
        "bucket": "next"
      }
    }
  ]
}
```

### POST /api/sync/apple/ack
同步桥确认某次变更已成功写回 Apple

---

## 5.5 AI 对话接口建议

虽然 AI 也可直接调通用 task API，但建议额外设计更高层接口：

### POST /api/assistant/capture
用于自然语言快速录入

### POST /api/assistant/organize
用于批量整理 Inbox

### GET /api/assistant/today
返回“今日清单”

### GET /api/assistant/review/waiting
返回 Waiting 列表

这样可减少 AI 侧业务拼装复杂度。

---

## 6. 同步桥设计

## 6.1 职责

同步桥负责：
- 首次全量拉取 Apple Reminders
- 建立 mapping
- 周期性扫描 Apple 变更
- 拉取后端变更
- 写回 Apple
- 本地持久化同步状态

## 6.2 运行方式

建议：
- 打包为 macOS 常驻程序
- 使用 LaunchAgent 启动
- 支持菜单栏状态显示（后续可选）

## 6.3 本地状态存储

可使用 SQLite 或 JSON 文件，至少保存：
- bridge_id
- 上次 pull 时间
- 上次 push 时间
- Apple reminder id 与 task id 缓存
- 最近同步错误

## 6.4 同步周期

第一阶段建议：
- 本地变更扫描：每 15~30 秒
- 服务端变更拉取：每 15~30 秒

后续可优化为：
- 本地事件触发 + 周期兜底

---

## 7. 字段映射策略

## 7.1 Apple -> Task

- Reminder.title -> tasks.title
- Reminder.notes -> tasks.note
- Reminder.dueDateComponents -> tasks.due_at
- Reminder.priority -> tasks.priority
- Reminder.isCompleted -> tasks.status/completed_at
- Reminder.list -> tasks.bucket（通过映射表或命名规则）

## 7.2 Task -> Apple

- tasks.title -> Reminder.title
- tasks.note -> Reminder.notes
- tasks.due_at -> Reminder.dueDateComponents
- tasks.priority -> Reminder.priority
- tasks.status=completed -> Reminder.isCompleted=true
- tasks.bucket -> Apple list / tag / note helper

## 7.3 高级语义处理

下列字段默认仅保存在后端：
- project_id
- AI 整理建议
- operation metadata
- 对话上下文信息

必要时可在 note 中加入轻量辅助标识，但第一阶段不建议过度编码。

---

## 8. 冲突处理策略

## 8.1 冲突定义

同一 task / reminder 在同步窗口内被不同来源修改。

## 8.2 第一阶段规则

- 不同字段更新：优先自动合并
- 相同字段冲突：last-write-wins
- 记录 conflict log

## 8.3 第二阶段可升级方向

- 字段级版本号
- 人工确认冲突
- 冲突摘要提醒

---

## 9. 安全设计

- 所有后端 API 走 HTTPS
- 同步桥使用专用 token 鉴权
- 每台桥接设备具备独立 bridge_id
- 服务端记录 bridge_id 与请求日志
- 敏感操作写日志

后续可选：
- IP allowlist
- token rotation
- bridge registration

---

## 10. 可观测性设计

建议记录：
- 每次同步 run 结果
- 新增/更新/完成/失败数量
- 同步耗时
- 冲突数
- 最近错误信息

后端可提供：
- /api/admin/sync-runs
- /api/admin/sync-errors

---

## 11. 第一阶段开发拆分

## Phase 1：后端核心
- 建库
- task / project / tag API
- operation log
- Apple mapping 表

## Phase 2：AI 接口层
- capture
- task query helpers
- today / waiting / inbox
- organize（基础版）

## Phase 3：Mac Sync Bridge MVP
- EventKit 读写 Reminders
- 首次全量同步
- 增量拉取 Apple 变更
- 拉取服务端变更并回写

## Phase 4：联调与冲突处理
- 双向测试
- 删除/完成/移动边界测试
- 网络失败重试

## Phase 5：运维与文档
- 部署文档
- 同步桥安装文档
- 故障排查文档

---

## 12. 接口约束与设计原则

- API 返回保持稳定、可预测
- 写接口尽量幂等
- 同步接口支持批量提交，避免单条高频调用
- 后端保留扩展字段空间，避免早期模型锁死

---

## 13. 为什么不以 CalDAV 为第一阶段核心

技术层面的主要原因：
- VTODO 兼容成本高
- Apple 客户端任务兼容行为不够稳定统一
- 会过早束缚任务模型
- AI/GTD 语义扩展不自由

因此第一阶段采用：
- 自有主库负责完整语义
- Apple Reminders 作为双向入口
- 后续再评估是否输出 CalDAV 层

---

## 14. 建议的目录结构

```text
projects/gtd/
  backend/
    app/
    alembic/
    tests/
  mac-sync-bridge/
    Sources/
    Tests/
  docs/
    PRD.md
    TECH_SPEC.md
```

---

## 15. 下一步建议

建议接下来继续输出以下文档：

1. API 详细定义（OpenAPI 草案）
2. 数据库 ER 图
3. 同步桥状态机设计
4. MVP 开发排期
5. Apple Reminders 映射规则文档

当前结论：

**以自有后端为核心、以 Mac 同步桥接入 Apple Reminders、以 AI 对话驱动 GTD 整理，是第一阶段最合理的工程落地路线。**
