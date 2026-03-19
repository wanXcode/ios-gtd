# API 规范（MVP + 下一阶段接口草案）

本文基于 `docs/PRD.md`、`docs/TECH_SPEC.md` 与当前 `backend/` 已落地代码编写。

目标有两个：

1. 作为当前后端实现的对齐文档，明确已实现接口的行为。
2. 作为后续开发接口设计稿，补齐 Apple Reminders 同步桥与 AI 助手所需接口。

为避免文档与代码脱节，本文对接口按两类标记：

- `已实现`：当前仓库内已有对应路由/模型支持。
- `规划中`：接口已完成设计，但当前后端尚未实现。

---

## 1. 基本约定

### 1.1 Base URL

- 本地开发：`http://127.0.0.1:8000/api`
- 文档内路径均默认相对 `/api`

### 1.2 认证

MVP 当前未接入认证。

后续建议统一采用：

- AI / 前端调用：`Authorization: Bearer <token>`
- Sync Bridge：独立 bridge token 或带设备标识的 JWT

在认证落地前，所有接口默认视为内网/受控环境使用。

### 1.3 内容类型

- 请求：`Content-Type: application/json`
- 响应：`application/json`
- 时间字段：ISO 8601 / RFC 3339，建议带时区，如 `2026-03-20T14:00:00+08:00`

### 1.4 ID 与时间

- 所有主键 ID 使用 UUID
- 时间统一存储为 `timestamptz`
- 未设置的时间字段返回 `null`

### 1.5 枚举值

#### Task.status

- `active`
- `completed`
- `archived`
- `deleted`

#### Task.bucket

- `inbox`
- `next`
- `waiting`
- `someday`
- `project`
- `done`

#### Project.status

- `active`
- `on_hold`
- `completed`

#### SyncState

- `active`
- `conflict`
- `deleted`

#### SyncRun.status

- `running`
- `success`
- `failed`

### 1.6 分页约定

MVP 当前已实现接口还未统一分页，默认直接返回列表。

后续建议统一升级为：

- `limit`：默认 `50`，最大 `200`
- `offset`：默认 `0`
- 响应增加：

```json
{
  "items": [],
  "total": 123,
  "limit": 50,
  "offset": 0
}
```

在分页改造前，已实现列表接口仍保持“直接返回数组”。

### 1.7 错误响应格式

当前 FastAPI/Pydantic 默认会返回标准校验错误结构。为便于前后端协作，后续建议统一包装为：

```json
{
  "error": {
    "code": "validation_error",
    "message": "Invalid request body",
    "details": [
      {
        "field": "title",
        "message": "Field required"
      }
    ]
  }
}
```

MVP 建议至少统一以下错误码语义：

| HTTP | code | 含义 |
| --- | --- | --- |
| 400 | `bad_request` | 请求参数不合法、状态迁移不允许 |
| 401 | `unauthorized` | 缺少认证或认证失败 |
| 403 | `forbidden` | 无权操作该资源 |
| 404 | `not_found` | 资源不存在 |
| 409 | `conflict` | 乐观锁版本冲突、同步冲突、唯一键冲突 |
| 422 | `validation_error` | 请求体字段校验失败 |
| 429 | `rate_limited` | 调用过频 |
| 500 | `internal_error` | 服务内部错误 |
| 503 | `service_unavailable` | 同步桥或依赖服务暂不可用 |

---

## 2. 数据对象

## 2.1 Task

```json
{
  "id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
  "title": "给客户回电话",
  "note": "讨论合同",
  "status": "active",
  "bucket": "inbox",
  "priority": 5,
  "due_at": "2026-03-20T14:00:00+08:00",
  "remind_at": null,
  "completed_at": null,
  "deleted_at": null,
  "source": "chat",
  "source_ref": "msg_123",
  "project_id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
  "created_at": "2026-03-19T08:00:00Z",
  "updated_at": "2026-03-19T08:00:00Z",
  "last_modified_by": "chat",
  "version": 1,
  "project": {
    "id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
    "name": "招聘",
    "description": "招聘相关任务",
    "status": "active",
    "created_at": "2026-03-18T10:00:00Z",
    "updated_at": "2026-03-18T10:00:00Z"
  },
  "tags": [
    {
      "id": "5be8f681-6efe-4841-8c74-a574dc49d9e1",
      "name": "work",
      "color": "blue",
      "created_at": "2026-03-18T10:00:00Z"
    }
  ]
}
```

字段说明：

- `status`：业务状态；完成后通常为 `completed`
- `bucket`：GTD 桶位；完成后通常切为 `done`
- `priority`：1-9，数字越大表示优先级越高
- `source`：数据来源，例如 `chat`、`apple_sync`、`api`
- `source_ref`：来源侧引用，例如消息 ID、Reminder ID、导入批次号
- `version`：任务业务版本号，本地每次有效修改都会递增
- `sync_change_id`：面向 Bridge 的单调递增变更序号，用于增量推送与 ack 对账
- `sync_pending`：该任务是否仍有待 Bridge 回写到 Apple 的本地改动
- `sync_last_pushed_at`：最近一次被 push 接口下发给 Bridge 的时间
- `is_all_day_due`：due_at 是否语义上属于“全天日期”而非精确时刻

## 2.2 Project

```json
{
  "id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
  "name": "招聘",
  "description": "招聘相关任务",
  "status": "active",
  "created_at": "2026-03-18T10:00:00Z",
  "updated_at": "2026-03-18T10:00:00Z"
}
```

## 2.3 Tag

```json
{
  "id": "5be8f681-6efe-4841-8c74-a574dc49d9e1",
  "name": "work",
  "color": "blue",
  "created_at": "2026-03-18T10:00:00Z"
}
```

## 2.4 AppleReminderMapping（已部分实现）

```json
{
  "id": "8f2028bb-aeb1-4375-81bd-5f8aeb9c2ef0",
  "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
  "apple_reminder_id": "x-apple-reminder://A1B2C3",
  "apple_list_id": "apple-list-001",
  "apple_calendar_id": "apple-calendar-001",
  "last_synced_task_version": 3,
  "last_seen_apple_modified_at": "2026-03-19T07:30:00Z",
  "sync_state": "active",
  "created_at": "2026-03-19T07:00:00Z",
  "updated_at": "2026-03-19T07:30:00Z"
}
```

## 2.5 SyncRun（已部分实现）

```json
{
  "id": "49ca9b2d-9ca6-4b32-a8c7-dc86c457968d",
  "bridge_id": "mac-mini-home",
  "started_at": "2026-03-19T07:00:00Z",
  "finished_at": "2026-03-19T07:00:12Z",
  "status": "success",
  "stats": {
    "pulled": 12,
    "pushed": 5,
    "conflicts": 1
  },
  "error_message": null
}
```

---

## 3. Health

## 3.1 GET /health

状态：`已实现`

用途：健康检查。

### 响应示例

```json
{
  "status": "ok",
  "app": "ios-gtd-backend",
  "env": "dev"
}
```

---

## 4. Projects

## 4.1 GET /projects

状态：`已实现`

用途：获取项目列表。

### 查询参数

MVP 当前无筛选参数。

后续建议支持：

- `status`
- `q`
- `updated_after`

### 响应示例

```json
[
  {
    "id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
    "name": "招聘",
    "description": "招聘相关任务",
    "status": "active",
    "created_at": "2026-03-18T10:00:00Z",
    "updated_at": "2026-03-18T10:00:00Z"
  }
]
```

## 4.2 POST /projects

状态：`已实现`

用途：创建项目。

### 请求体

```json
{
  "name": "招聘",
  "description": "招聘相关任务"
}
```

### 字段说明

- `name`：必填，建议后续加唯一约束或同名检测
- `description`：可选

### 成功响应

`201 Created`

```json
{
  "id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
  "name": "招聘",
  "description": "招聘相关任务",
  "status": "active",
  "created_at": "2026-03-18T10:00:00Z",
  "updated_at": "2026-03-18T10:00:00Z"
}
```

## 4.3 GET /projects/{id}

状态：`规划中`

用途：获取单个项目详情，用于任务详情页、项目整理界面。

## 4.4 PATCH /projects/{id}

状态：`规划中`

用途：修改项目名称、描述、状态。

### 请求体示例

```json
{
  "name": "招聘 Q2",
  "description": "第二季度招聘推进",
  "status": "active"
}
```

## 4.5 DELETE /projects/{id}

状态：`规划中`

用途：删除或归档项目。

建议：

- MVP 不做物理删除，优先将 `status` 设为 `completed` 或 `archived`
- 如果必须删除，应先处理关联任务的 `project_id`

---

## 5. Tags

## 5.1 GET /tags

状态：`已实现`

用途：获取标签列表。

### 响应示例

```json
[
  {
    "id": "5be8f681-6efe-4841-8c74-a574dc49d9e1",
    "name": "work",
    "color": "blue",
    "created_at": "2026-03-18T10:00:00Z"
  }
]
```

## 5.2 POST /tags

状态：`已实现`

用途：创建标签。

### 请求体

```json
{
  "name": "work",
  "color": "blue"
}
```

### 字段说明

- `name`：必填，数据库中唯一
- `color`：可选，当前为自由字符串，后续可规范成固定色板

## 5.3 PATCH /tags/{id}

状态：`规划中`

用途：修改标签名称或颜色。

## 5.4 DELETE /tags/{id}

状态：`规划中`

用途：删除标签。应同时移除 `task_tags` 映射。

---

## 6. Tasks

## 6.1 GET /tasks

状态：`已实现`

用途：查询任务列表。

### 已支持筛选参数

- `bucket`
- `status`
- `project_id`
- `due_before`
- `due_after`
- `updated_after`
- `q`

### 建议补充筛选参数

- `tag_id`
- `tag_ids`（多标签交集或并集需明确）
- `priority_gte`
- `priority_lte`
- `has_due`（true/false）
- `is_overdue`（true/false）
- `assigned_view`（如 `today` / `waiting` / `inbox`）
- `include_deleted`（true/false）
- `sort_by`（`created_at` / `updated_at` / `due_at` / `priority`）
- `sort_order`（`asc` / `desc`）

### 请求示例

`GET /tasks?bucket=inbox&status=active&q=合同`

### 响应示例

```json
[
  {
    "id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
    "title": "给客户回电话",
    "note": "讨论合同",
    "status": "active",
    "bucket": "inbox",
    "priority": 5,
    "due_at": "2026-03-20T14:00:00+08:00",
    "remind_at": null,
    "completed_at": null,
    "deleted_at": null,
    "source": "chat",
    "source_ref": "msg_123",
    "project_id": null,
    "created_at": "2026-03-19T08:00:00Z",
    "updated_at": "2026-03-19T08:00:00Z",
    "last_modified_by": "chat",
    "version": 1,
    "project": null,
    "tags": []
  }
]
```

## 6.2 POST /tasks

状态：`已实现`

用途：创建任务。

### 请求体

```json
{
  "title": "给客户回电话",
  "note": "讨论合同",
  "status": "active",
  "bucket": "inbox",
  "priority": 5,
  "due_at": "2026-03-20T14:00:00+08:00",
  "remind_at": null,
  "source": "chat",
  "source_ref": "msg_123",
  "project_id": null,
  "tag_ids": [],
  "last_modified_by": "chat"
}
```

### 字段说明

- `title`：必填，1-255 字符
- `status`：默认 `active`
- `bucket`：默认 `inbox`
- `priority`：可选，范围 1-9
- `project_id`：可选
- `tag_ids`：可选，UUID 数组
- `last_modified_by`：默认 `api`，建议 chat / sync / manual 等来源显式填写

### 业务约束建议

当前代码层校验主要依赖 schema。建议补充以下服务层校验：

- `status=completed` 时，若 `completed_at` 为空则自动填充
- `bucket=done` 时，若 `status` 仍为 `active`，应明确是否允许
- `project_id` 必须存在
- `tag_ids` 必须全部存在

### 成功响应

`201 Created`

返回完整 `TaskRead`。

## 6.3 GET /tasks/{id}

状态：`已实现`

用途：获取单个任务详情。

### 路径参数

- `id`：任务 UUID

### 成功响应

`200 OK`，返回 `TaskRead`

### 失败响应

当前实现返回：

- `404` + `detail: "Task not found"`

后续可再统一包装为标准错误码结构。

## 6.4 PATCH /tasks/{id}

状态：`已实现`

用途：更新任务，支持部分字段修改。

### 请求体示例

```json
{
  "title": "给客户回电话（合同版本）",
  "bucket": "next",
  "priority": 7,
  "project_id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
  "tag_ids": [
    "5be8f681-6efe-4841-8c74-a574dc49d9e1"
  ],
  "last_modified_by": "chat"
}
```

### 可更新字段

- `title`
- `note`
- `status`
- `bucket`
- `priority`
- `due_at`
- `remind_at`
- `completed_at`
- `deleted_at`
- `source`
- `source_ref`
- `project_id`
- `tag_ids`
- `last_modified_by`

### 并发控制建议

当前模型已有 `version` 字段，但接口尚未使用。

后续建议两种方式二选一：

1. 请求体传 `version`
2. 使用 `If-Match: W/"<version>"`

版本不一致时返回：

```json
{
  "error": {
    "code": "conflict",
    "message": "Task version conflict"
  }
}
```

HTTP 状态码：`409 Conflict`

## 6.5 DELETE /tasks/{id}

状态：`已实现`

用途：删除任务。

### 当前行为

当前为物理删除。

### 后续建议

升级为软删除：

- `status = deleted`
- `deleted_at = now()`
- 保留 operation log 与 sync mapping

对于 Apple Reminders 已映射任务，应触发待同步删除事件，而不是直接丢失上下文。

## 6.6 POST /tasks/{id}/complete

状态：`已实现`

用途：完成任务。

### 行为建议

调用后应至少确保：

- `status = completed`
- `bucket = done`
- `completed_at = now()`
- `last_modified_by` 更新为当前来源
- `version += 1`

### 响应示例

返回更新后的 `TaskRead`。

## 6.7 POST /tasks/{id}/reopen

状态：`规划中`

用途：将已完成任务重新打开。

### 请求体示例

```json
{
  "bucket": "next",
  "last_modified_by": "chat"
}
```

### 建议行为

- `status = active`
- `completed_at = null`
- `bucket` 默认恢复为 `next`，也可由请求指定
- 写入 operation log
- 若已存在 Apple mapping，则加入待回写队列

## 6.8 POST /tasks/batch-update

状态：`规划中`

用途：批量整理任务，服务于对话式 GTD 操作。

### 请求体

```json
{
  "task_ids": [
    "1dbe18f0-91df-454f-b53e-5426f5ee54db",
    "278a6ca4-b2f8-4470-9cd7-9d98a248f78e"
  ],
  "changes": {
    "bucket": "next",
    "project_id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
    "tag_ids": [
      "5be8f681-6efe-4841-8c74-a574dc49d9e1"
    ],
    "last_modified_by": "chat"
  }
}
```

### 响应示例

```json
{
  "updated": 2,
  "items": [
    {
      "id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "status": "active",
      "bucket": "next"
    },
    {
      "id": "278a6ca4-b2f8-4470-9cd7-9d98a248f78e",
      "status": "active",
      "bucket": "next"
    }
  ]
}
```

### 设计要点

- 默认全成功或全失败，保证批量整理一致性
- 如果要支持部分成功，需额外返回 `failed_items`
- 需限制单次批量数量，建议 `<= 200`

## 6.9 GET /tasks/views/today

状态：`规划中`

用途：返回“今天要做”的任务视图，供 AI 与未来前端直接调用。

### 查询参数

- `include_overdue=true|false`，默认 `true`
- `timezone=Asia/Shanghai`

### 筛选语义建议

- `status = active`
- `bucket != someday`
- `due_at` 落在今日内，或逾期未完成

## 6.10 GET /tasks/views/waiting

状态：`规划中`

用途：返回 Waiting 列表。

### 筛选语义

- `bucket = waiting`
- `status = active`

## 6.11 GET /tasks/views/inbox

状态：`规划中`

用途：返回待整理 Inbox 列表。

### 筛选语义

- `bucket = inbox`
- `status = active`

---

## 7. Sync / Apple Reminders Bridge

这一组接口当前 `未实现`，但它们是 PRD 里“线上主库 + Apple 原生入口 + 双向同步”的核心闭环。

设计目标：

- 让 macOS 上的 Sync Bridge 能安全地做增量拉取与回写
- 让后端保留同步日志、冲突信息与重试能力
- 尽量避免把 Apple EventKit 细节直接泄漏进通用任务接口

## 7.1 POST /sync/bridges/register

状态：`规划中`

用途：注册或更新一台同步桥设备。

### 请求体

```json
{
  "bridge_id": "mac-mini-home",
  "device_name": "Mac mini Home",
  "app_version": "0.1.0",
  "capabilities": ["pull", "push", "ack"],
  "platform": "macOS 15.0"
}
```

### 响应

```json
{
  "bridge_id": "mac-mini-home",
  "status": "active",
  "server_time": "2026-03-19T08:00:00Z"
}
```

## 7.2 POST /sync/runs/start

状态：`规划中`

用途：开始一次同步运行并创建 `sync_runs` 记录。

### 请求体

```json
{
  "bridge_id": "mac-mini-home"
}
```

### 响应

```json
{
  "run_id": "49ca9b2d-9ca6-4b32-a8c7-dc86c457968d",
  "started_at": "2026-03-19T08:00:00Z",
  "status": "running"
}
```

## 7.3 POST /sync/apple/pull

状态：`已实现`

用途：由 Sync Bridge 把 Apple Reminders 侧增量变更提交给后端，并推进该 bridge 在后端侧的持久 checkpoint。

这是“手机/Reminders 改了什么，后端吃进去”的入口。

### 请求体

```json
{
  "run_id": "49ca9b2d-9ca6-4b32-a8c7-dc86c457968d",
  "bridge_id": "mac-mini-home",
  "changes": [
    {
      "change_type": "upsert",
      "apple_reminder_id": "x-apple-reminder://A1B2C3",
      "apple_list_id": "apple-list-001",
      "apple_calendar_id": "apple-calendar-001",
      "apple_modified_at": "2026-03-19T07:58:00Z",
      "payload": {
        "title": "周五提醒我看 xmirror 的 SEO",
        "note": null,
        "is_completed": false,
        "due_at": "2026-03-20T09:00:00+08:00",
        "remind_at": null,
        "list_name": "Inbox"
      }
    },
    {
      "change_type": "delete",
      "apple_reminder_id": "x-apple-reminder://D9E8F7",
      "apple_modified_at": "2026-03-19T07:59:00Z"
    }
  ]
}
```

### change_type

- `upsert`：新增或更新 Reminder
- `delete`：Apple 侧已删除

### 当前语义

- `pull` 直接接收 `changes[]`，支持 `upsert` / `delete`
- 若 `apple_reminder_id` 已有 mapping，则尝试更新既有任务
- 若无 mapping 且为 `upsert`，后端会新建 task + mapping
- 若本地任务仍处于 `sync_pending=true`，且远端修改时间晚于上次看到的 Apple 时间，同时本地任务也在 mapping 更新时间后发生过本地修改，则标记为 `conflict`
- `delete` 会把本地 task 软删除，而不是物理删除
- 后端会按 `bridge_id` 持久化 `backend_cursor / last_pull_cursor / last_pull_succeeded_at`
- 响应内会返回当前 backend 视角的 `checkpoint` 快照，便于 bridge 对账

### 响应示例

```json
{
  "ok": true,
  "mode": "pull",
  "bridge_id": "mac-mini-home",
  "cursor": "c1",
  "next_cursor": "2026-03-19T07:59:00+00:00",
  "accepted": 2,
  "applied": 1,
  "conflicts": 1,
  "results": [
    {
      "apple_reminder_id": "x-apple-reminder://A1B2C3",
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "result": "applied"
    },
    {
      "apple_reminder_id": "x-apple-reminder://D9E8F7",
      "result": "conflict",
      "reason": "task_modified_after_last_sync"
    }
  ],
  "checkpoint": {
    "bridge_id": "mac-mini-home",
    "backend_cursor": "2026-03-19T07:59:00+00:00",
    "last_pull_cursor": "c1",
    "last_push_cursor": null,
    "last_acked_change_id": null,
    "last_seen_change_id": null
  }
}
```

### 冲突策略建议

MVP 建议先采用保守策略：

- 以 `version` + `last_seen_apple_modified_at` 判断是否冲突
- 冲突时不自动覆盖，记录 `sync_state = conflict`
- AI 或管理接口可后续查看并处理

## 7.4 POST /sync/apple/push

状态：`已实现`

用途：由 Sync Bridge 拉取“服务端待回写到 Apple Reminders”的任务变更。

这是“对话或 API 改了任务，桥接程序要怎么回写 Apple”的出口。

### 请求体

- `bridge_id`：必填
- `cursor`：可选，bridge 已确认看过的最大 `change_id` 游标；后端会尽量不重复返回 `<= cursor` 的本地变更
- `tasks[]`：可选，bridge 已知 task 版本摘要；若后端版本不高于该值，则可跳过返回
- `limit`：默认 100

### 响应示例

```json
{
  "ok": true,
  "mode": "push",
  "bridge_id": "mac-mini-home",
  "cursor": "11",
  "next_cursor": "14",
  "items": [
    {
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "version": 4,
      "change_id": 14,
      "operation": "upsert",
      "mapping": {
        "apple_reminder_id": "x-apple-reminder://A1B2C3",
        "apple_list_id": "apple-list-001",
        "apple_calendar_id": "apple-calendar-001",
        "sync_state": "active",
        "last_ack_status": "failed",
        "last_error_code": "eventkit_timeout",
        "last_error_message": "Save reminder timeout"
      },
      "task": {
        "title": "给客户回电话",
        "note": "讨论合同",
        "status": "active",
        "bucket": "next",
        "priority": 7,
        "due_at": "2026-03-20T14:00:00+08:00",
        "remind_at": null,
        "completed_at": null
      }
    }
  ],
  "checkpoint": {
    "bridge_id": "mac-mini-home",
    "backend_cursor": "2026-03-19T07:59:00+00:00",
    "last_pull_cursor": "c1",
    "last_push_cursor": "14",
    "last_acked_change_id": 11,
    "last_seen_change_id": 14
  }
}
```

### 当前语义

- `push` 为 POST，便于带上 bridge 已知版本与 cursor
- 默认会返回 `sync_pending=true` 的任务，或 mapping 上仍有 `pending_operation` 的任务
- 若请求带了 `cursor`，后端会尽量跳过 `change_id <= cursor` 的本地变更，降低 replay 风险
- 若 mapping 已记录 `last_ack_status in {success, acked}` 且 `last_push_change_id == task.sync_change_id`，后端会跳过该条，减少重复 write-back
- 返回字段中已包含 `change_id`、mapping、task 快照和 `operation`
- `operation` 当前可能是 `upsert` / `complete` / `delete`
- `push` 会记录 `sync_last_pushed_at`，但不会因为“仅下发未 ack”就清掉 pending
- 响应内会返回当前 bridge 对应的 `checkpoint` 快照

### operation

- `upsert`
- `delete`
- `complete`

## 7.5 POST /sync/apple/ack

状态：`已实现`

用途：Sync Bridge 在成功写回 Apple Reminders 后确认 ack，更新 mapping 与出队状态。

### 请求体

```json
{
  "bridge_id": "mac-mini-home",
  "acks": [
    {
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "version": 4,
      "status": "success",
      "remote_id": "x-apple-reminder://A1B2C3",
      "apple_modified_at": "2026-03-19T08:01:00Z"
    },
    {
      "task_id": "278a6ca4-b2f8-4470-9cd7-9d98a248f78e",
      "version": 2,
      "status": "failed",
      "error_code": "apple_permission_denied",
      "error_message": "EventKit write permission denied",
      "retryable": true
    }
  ]
}
```

### 当前语义

- `ack` 支持 `success` / `acked` / `failed` / `conflict`
- `success|acked`：更新 mapping、清除 `sync_pending`、更新 `last_synced_task_version` 与 `last_push_change_id`
- `failed`：保留 `sync_pending=true`，等待后续重试；`retryable=true` 仅作为错误语义补充，当前不单独建后端 retry queue
- `conflict`：mapping 会进入 `sync_state=conflict`
- 若 ack 的 `version` 小于 mapping 已知的 `last_synced_task_version`，后端会返回 `stale_ignored`，避免旧回执覆盖新状态
- 若 ack 的 `version` 大于当前 `task.version`，后端会返回 HTTP 409，阻止不可能的未来版本写入
- 若显式传入 `change_id` 但该 delivery ledger 不存在，后端会返回 HTTP 409；若该 `change_id` 已成功 ack 过，则返回 `stale_ignored`
- 重试重新 push 同一 `change_id` 时，后端会复用同一条 delivery ledger，并清空上次失败错误细节，避免 bridge 把旧错误误认为本轮结果
- ack 成功时会推进 `sync_bridge_states.last_acked_change_id`

### 响应示例

```json
{
  "ok": true,
  "mode": "ack",
  "bridge_id": "mac-mini-home",
  "acked": [
    {
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "remote_id": "x-apple-reminder://A1B2C3",
      "version": 4,
      "change_id": 14,
      "status": "success"
    },
    {
      "task_id": "278a6ca4-b2f8-4470-9cd7-9d98a248f78e",
      "remote_id": "x-apple-reminder://D9E8F7",
      "version": 1,
      "change_id": 13,
      "status": "stale_ignored"
    }
  ],
  "success": 1,
  "failed": 1,
  "conflict": 0,
  "checkpoint": {
    "bridge_id": "mac-mini-home",
    "backend_cursor": "2026-03-19T07:59:00+00:00",
    "last_pull_cursor": "c1",
    "last_push_cursor": "14",
    "last_acked_change_id": 14,
    "last_seen_change_id": 14
  }
}
```

## 7.6 GET /sync/apple/state/{bridge_id}

状态：`已实现`

用途：读取 backend 为指定 bridge 持久化的 checkpoint / cursor / 最近错误状态，便于 bridge 冷启动恢复和联调排障。

### 响应示例

```json
{
  "bridge_id": "mac-mini-home",
  "backend_cursor": "2026-03-19T07:59:00+00:00",
  "last_pull_cursor": "c1",
  "last_push_cursor": "14",
  "last_acked_change_id": 14,
  "last_failed_change_id": null,
  "last_seen_change_id": 14,
  "pending_delivery_count": 1,
  "last_pull_started_at": "2026-03-19T08:00:00+00:00",
  "last_pull_succeeded_at": "2026-03-19T08:00:02+00:00",
  "last_push_started_at": "2026-03-19T08:00:03+00:00",
  "last_push_succeeded_at": "2026-03-19T08:00:04+00:00",
  "last_ack_started_at": "2026-03-19T08:00:05+00:00",
  "last_ack_succeeded_at": "2026-03-19T08:00:05+00:00",
  "last_error_code": null,
  "last_error_message": null,
  "recent_deliveries": [
    {
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "change_id": 14,
      "task_version": 4,
      "operation": "upsert",
      "status": "pending",
      "attempt_count": 2,
      "retryable": false,
      "remote_id": "x-apple-reminder://A1B2C3",
      "last_error_code": null,
      "last_error_message": null,
      "first_pushed_at": "2026-03-19T08:00:03+00:00",
      "last_pushed_at": "2026-03-19T08:02:03+00:00",
      "acked_at": null,
      "failed_at": null
    }
  ]
}
```

### 当前语义

- `state` 是 bridge 冷启动/排障读接口，不会修改业务状态
- `pending_delivery_count` 统计该 bridge 下当前仍未收敛的 delivery（`pending / retryable_failed / failed / conflict`）
- `recent_deliveries[]` 返回最近 10 条 delivery 摘要，便于 bridge 启动时快速判断是否存在悬挂 write-back、冲突或失败重试

## 7.7 POST /sync/runs/{id}/finish

状态：`规划中`

用途：结束同步运行，写入统计信息。

### 请求体

```json
{
  "status": "success",
  "stats": {
    "pulled": 12,
    "pushed": 5,
    "acked": 5,
    "conflicts": 1,
    "failed": 0
  },
  "error_message": null
}
```

## 7.8 GET /sync/runs

状态：`规划中`

用途：查看同步历史。

### 查询参数

- `bridge_id`
- `status`
- `started_after`
- `limit`
- `offset`

## 7.9 GET /sync/conflicts

状态：`规划中`

用途：查看同步冲突列表，便于后续人工处理或 AI 辅助整理。

### 查询参数

- `bridge_id`
- `task_id`
- `status=open|resolved`

---

## 8. Assistant / AI 对话接口

这组接口面向“AI 对话层”，目标不是替代底层 CRUD，而是减少 prompt 侧拼装逻辑，让常见 GTD 动作用更稳定的后端语义表达。

## 8.1 POST /assistant/capture

状态：`部分已实现`

用途：把自然语言快速捕获为任务。

### 请求体

```json
{
  "input": "下周前把合同发出去",
  "context": {
    "timezone": "Asia/Shanghai",
    "source": "chat",
    "source_ref": "msg_123"
  },
  "dry_run": false
}
```

### 响应示例

```json
{
  "task": {
    "id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
    "title": "把合同发出去",
    "bucket": "inbox",
    "status": "active",
    "due_at": "2026-03-26T18:00:00+08:00"
  },
  "parsed": {
    "title": "把合同发出去",
    "time_expression": "下周前",
    "confidence": 0.78
  }
}
```

### 当前已实现范围

- 已提供最小可用路由：`POST /api/assistant/capture`
- 支持 `dry_run=true`：只返回解析结果，不落库
- 支持最小上下文：`timezone`、`source`、`source_ref`、`actor`
- 当前解析策略为启发式规则，不依赖 LLM：
  - 可识别少量中文时间表达（如 `今天`、`明天`、`下周`）
  - 解析失败时保底策略：原文作为 `title`，进 `inbox`
  - 当前会把原始输入保存在任务 `note` 中，便于后续二次整理

### 设计建议

- 后续可把启发式 parser 升级为独立 NLP / LLM 解析层
- 对时间表达建议补充更精细的语义（工作日、本周五、月底前等）

## 8.2 POST /assistant/plan

状态：`规划中`

用途：把自然语言改写为结构化任务更新意图，但不直接执行。

### 请求体

```json
{
  "input": "把所有等待别人回复的任务列出来",
  "context": {
    "timezone": "Asia/Shanghai"
  }
}
```

### 响应示例

```json
{
  "intent": "query_tasks",
  "filters": {
    "bucket": "waiting",
    "status": "active"
  },
  "confidence": 0.95
}
```

## 8.3 POST /assistant/execute

状态：`规划中`

用途：执行结构化助手动作，适合把 LLM 推理与实际数据写操作分层。

### 请求体

```json
{
  "action": "batch_update_tasks",
  "payload": {
    "task_ids": [
      "1dbe18f0-91df-454f-b53e-5426f5ee54db"
    ],
    "changes": {
      "bucket": "waiting",
      "last_modified_by": "chat"
    }
  }
}
```

### 支持动作建议

- `create_task`
- `update_task`
- `complete_task`
- `reopen_task`
- `batch_update_tasks`
- `query_tasks`
- `create_project`
- `create_tag`

## 8.4 POST /assistant/inbox-organize

状态：`规划中`

用途：针对 Inbox 任务生成整理建议，或直接批量落地。

### 请求体

```json
{
  "task_ids": [
    "1dbe18f0-91df-454f-b53e-5426f5ee54db",
    "278a6ca4-b2f8-4470-9cd7-9d98a248f78e"
  ],
  "mode": "suggest"
}
```

### mode

- `suggest`：只给建议
- `apply`：直接执行

### 响应示例

```json
{
  "items": [
    {
      "task_id": "1dbe18f0-91df-454f-b53e-5426f5ee54db",
      "suggestion": {
        "bucket": "next",
        "project_name": "招聘",
        "reason": "该任务具备明确下一步动作"
      }
    }
  ]
}
```

## 8.5 GET /assistant/views/today

状态：`部分已实现`

用途：为对话层提供“今天做什么”的稳定视图。

### 查询参数

- `timezone`
- `include_overdue`
- `limit`

### 当前已实现范围

- 已提供最小可用路由：`GET /api/assistant/views/today`
- 当前筛选逻辑：
  - `status = active`
  - `deleted_at is null`
  - `bucket != someday`
  - `due_at != null`
  - `include_overdue=true` 时返回“今日到期 + 已逾期”
- 当前按 `due_at asc, priority desc, created_at asc` 排序

## 8.6 GET /assistant/views/waiting

状态：`部分已实现`

用途：返回等待中任务列表。

### 当前已实现范围

- 已提供最小可用路由：`GET /api/assistant/views/waiting`
- 当前筛选逻辑：
  - `bucket = waiting`
  - `status = active`
  - `deleted_at is null`

## 8.7 GET /assistant/views/project-summary

状态：`规划中`

用途：按项目输出任务汇总，支持 AI 直接拿来生成回答。

### 查询参数

- `project_id`
- `include_completed`

### 响应示例

```json
{
  "project": {
    "id": "c4ec7a8f-4d0d-4f3b-a16f-79d17780d73a",
    "name": "招聘"
  },
  "summary": {
    "active": 12,
    "completed": 8,
    "overdue": 2,
    "waiting": 3
  },
  "tasks": []
}
```

---

## 9. 推荐状态迁移规则

为避免接口实现时出现互相打架，建议服务层明确以下规则。

## 9.1 完成任务

当任务被 complete：

- `status -> completed`
- `bucket -> done`
- `completed_at -> now()`
- `deleted_at -> null`

## 9.2 重开任务

当任务被 reopen：

- `status -> active`
- `completed_at -> null`
- `bucket -> next`（默认）或调用方指定

## 9.3 删除任务

MVP 当前允许物理删除，但建议尽快切换成软删除：

- `status -> deleted`
- `deleted_at -> now()`
- 不再出现在默认查询里

## 9.4 归档任务

归档不等于完成：

- `status -> archived`
- `bucket` 保持原值或切到专用归档视图

---

## 10. 最小实现优先级建议

为了让文档能直接指导开发，建议按下面顺序落地：

### P0

1. `POST /tasks/{id}/reopen`
2. `POST /tasks/batch-update`
3. `GET /tasks` 增加 done / deleted 过滤语义校准
4. `operation_logs` 自动写入

### P1

5. `POST /sync/runs/start`
6. `POST /sync/apple/pull`
7. `GET /sync/apple/push`
8. `POST /sync/apple/ack`
9. `POST /sync/runs/{id}/finish`

### P2

10. `POST /assistant/capture`
11. `POST /assistant/inbox-organize`
12. `GET /assistant/views/today`

---

## 11. 与当前代码的差异说明

当前仓库实际已实现的仅包括：

- `GET /health`
- `GET/POST /projects`
- `GET/POST /tags`
- `GET/POST /tasks`
- `GET/PATCH/DELETE /tasks/{id}`
- `POST /tasks/{id}/complete`

以下内容在本文中属于“设计先行，代码未落地”：

- Project/Tag 的 patch/delete/detail
- Task 的 reopen、batch-update、视图接口
- 全部 sync 接口
- 全部 assistant 接口
- 统一认证、分页、错误包装、乐观锁

开发时应以“文档指导实现，但不误导当前已上线能力”为原则。