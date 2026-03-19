# Mac Sync Bridge 设计规范（MVP 草案）

## 1. 文档目标

本文档细化 `Mac Sync Bridge` 的职责边界、运行形态、同步状态机、字段映射、冲突与错误恢复策略，作为后续实现 macOS 同步代理的直接设计输入。

它承接：
- `docs/PRD.md`
- `docs/TECH_SPEC.md`

目标不是一次性定义所有高级能力，而是让后续开发可以直接开始写代码、搭骨架、补接口。

---

## 2. Bridge 的定位

`Mac Sync Bridge` 是运行在用户 macOS 设备上的本地同步代理。

它处于 Apple Reminders / EventKit 与 GTD Backend 之间，负责把：
- Apple Reminders 中的新增、修改、完成、删除
- 同步到线上任务主库

同时把：
- 后端任务系统中的可映射变更
- 回写到 Apple Reminders

### 2.1 核心原则

1. **后端主库优先**：线上 task 是系统语义主对象。
2. **本地入口优先**：Reminders 仍是用户高频入口，桥要尽量“无感同步”。
3. **桥本身尽量无业务语义**：Bridge 不做复杂 GTD 推理，只做映射、传输、状态维护。
4. **可恢复优先于绝对实时**：MVP 允许秒级延迟，但必须能在异常后恢复。
5. **字段级最小同步**：尽量只同步明确支持的字段，不把复杂 GTD 元数据硬塞进 Reminder note。

---

## 3. 职责边界

## 3.1 Bridge 负责什么

### A. 连接 Apple Reminders
- 获取 Reminders 访问授权
- 枚举 Reminder lists / reminders
- 读取 reminder 关键字段
- 写入 / 更新 / 完成 / 删除 reminder

### B. 维护本地同步状态
- 生成并持久化 `bridge_id`
- 保存本地 checkpoint（上次扫描时间、上次 push cursor 等）
- 保存 reminder 与 task 的映射缓存
- 保存待重试任务与失败日志

### C. 与后端同步
- 批量上报 Apple 侧变更（pull to backend）
- 批量拉取后端待下发变更（push to Apple）
- 对已成功写入的变更做 ack

### D. 冲突与恢复
- 基于本地 mapping + backend 返回结果识别冲突
- 执行 MVP 级别冲突规则
- 网络失败、本地写入失败时重试

---

## 3.2 Bridge 不负责什么

以下内容留在后端或 AI 层：

- GTD 智能整理
- 项目归属推理
- 标签推荐
- 自然语言解析
- 多端协同仲裁的完整业务规则
- 高级人工冲突 UI

Bridge 只处理“同步所需最小语义”。

---

## 4. 运行方式

## 4.1 MVP 运行形态

推荐形态：
- Swift 实现
- macOS 本地常驻进程
- 通过 LaunchAgent 开机自启 / 登录启动
- 无 UI 或仅保留极简菜单栏壳

MVP 建议先做：
1. `BridgeCLI`：命令行可启动单次同步 / 前台常驻
2. `BridgeApp`：后续再接 LaunchAgent / 菜单栏外壳

这样便于先把同步逻辑跑通。

## 4.2 建议进程模型

一个单进程内包含以下逻辑循环：

1. 启动初始化
2. 权限检查
3. 本地 checkpoint 加载
4. EventKit 扫描 Apple 侧变更
5. 调后端 `pull`
6. 调后端 `push`
7. 回写 Apple
8. `ack`
9. 更新 checkpoint
10. sleep 15~30 秒

## 4.3 并发原则

MVP 不建议多线程乱并发写 EventKit。

建议：
- 网络拉取与本地扫描可串行
- Apple 写入串行执行
- 单轮 sync run 内以“批处理 + 串行提交”为主
- 保证同一 reminder 在同一时刻只有一个 writer

原因：
- EventKit 不是高吞吐写入系统
- 同一个 reminder 并发 save 容易产生意外覆盖
- 同步桥更需要稳定，不需要极致吞吐

---

## 5. 模块划分

建议分为以下模块：

## 5.1 BridgeCore
负责同步主流程与状态机：
- SyncCoordinator
- PullPlanner
- PushPlanner
- ConflictResolver
- RetryScheduler
- SyncRunReporter

## 5.2 EventKitAdapter
负责 Apple Reminders 访问：
- 权限申请
- list / reminder 查询
- reminder 更新与保存
- 本地字段标准化输出

### 5.2.1 当前 EventKit adapter 结构（2026-03）

当前仓库中 `EventKitAdapter/ReminderStore.swift` 已不再只是 in-memory fake，而是补到接近真实适配层的边界：

- `ReminderStore`
  - `authorizationStatus()`
  - `requestAccessIfNeeded()`
  - `fetchReminders()`
  - `upsert(reminders:)`
  - `delete(reminders:)`
- `EventKitReminderStoreConfiguration`
  - `syncedListIdentifiers`
  - `defaultListIdentifier`
  - `includeCompleted`
  - `scanWindow`
- `ReminderDTOConverting`
  - 负责 `EKReminder` ↔ `ReminderRecord` 的字段归一化与 fingerprint 生成
- `EventKitReminderStore`
  - 负责授权、扫描、DTO 转换、写入、删除
  - 非 macOS / 无 EventKit 环境下提供 stub fallback，避免其他 target 被平台依赖卡死

当前实现重点是把模块边界和真实流程定型：
- 授权 -> list discovery -> scan -> DTO -> upsert/delete
- BridgeCore 继续只依赖 `ReminderStore` 协议，不直接碰 `EKEventStore`
- `ReminderStore` 已补 `fetchReminderLists()`，方便 bridge 做 list mapping / doctor / 配置校验

后续真机联调时主要再补：
- 全天任务 / 时区更精细转换（当前已先补一个 all-day due 写回骨架）
- `lastModifiedDate` 稳定性验证
- 删除缺失检测策略
- 更细的 list / bucket 映射器

## 5.3 HTTPClient
负责后端 API：
- `POST /api/sync/apple/pull`
- `POST /api/sync/apple/push`
- `POST /api/sync/apple/ack`
- 鉴权、重试、超时、错误解析

### 5.3.1 当前 HTTP client scaffold 约定

当前仓库内已经有一版更真实的 `URLSessionBackendSyncClient` scaffold，接口边界如下：

- `BackendSyncClient`
  - `pullChanges(request:)`
  - `pushChanges(request:)`
  - `ackChanges(request:)`
- `BackendClientConfiguration`
  - `baseURL`
  - `apiToken`
  - `timeout`
  - `additionalHeaders`
  - `jsonEncoder` / `jsonDecoder`
- `BackendEndpointSet`
  - 默认 path：
    - `/api/sync/apple/pull`
    - `/api/sync/apple/push`
    - `/api/sync/apple/ack`
- `URLSessioning`
  - 方便测试注入 mock session
- `BackendClientError`
  - `invalidResponse`
  - `unexpectedStatusCode`
  - `encodingFailed`
  - `invalidURL`

这层现在已经能承担真实实现的主要职责：
- 组装 URLRequest
- 注入 Bearer token
- 使用 snake_case 与 backend payload 对齐
- 把 backend 当前 `pull / push / ack` 返回体转换到内部 `BridgeModels`
- 校验 2xx 状态码
- 暴露明确错误（含 decode failure）

当前已开始按 backend 真实 payload 对齐：
- pull: `bridge_id + cursor + limit + changes[]` -> `accepted/applied/results/checkpoint`
- push: `bridge_id + cursor + tasks[]` -> `mode/items/checkpoint`
- ack: `bridge_id + acks[]` -> `success/checkpoint`

后续联调重点不再是“是否要抽协议”，而是：
- 最终请求/响应 payload 是否完全跟 backend 契约对齐
- reject / partial failure 的正式返回体
- cursor/change_id/version 的最终约定
- 是否需要补 query/header 字段
- 是否要加入 retry / metrics / tracing

## 5.4 Persistence
负责本地状态持久化：
- SQLite（优先）或 JSON
- checkpoint
- mapping cache
- pending ack
- failed operations
- config cache

### 5.4.1 SQLite schema 草案

当前 scaffold 已经明确一版 SQLite schema 草案，建议按 migration 方式落地。核心表如下。

#### `bridge_configuration`

```sql
CREATE TABLE IF NOT EXISTS bridge_configuration (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    backend_base_url TEXT NOT NULL,
    api_token TEXT,
    sync_interval_seconds REAL NOT NULL,
    default_reminder_list_identifier TEXT,
    updated_at TEXT NOT NULL
);
```

用途：
- 单行配置表
- 记录 backend 地址、token、同步频率、默认 reminder list

#### `sync_checkpoint`

```sql
CREATE TABLE IF NOT EXISTS sync_checkpoint (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    backend_cursor TEXT,
    last_successful_sync_at TEXT,
    last_successful_pull_at TEXT,
    last_successful_push_at TEXT,
    last_successful_ack_at TEXT,
    last_apple_scan_started_at TEXT,
    last_sync_status TEXT,
    updated_at TEXT NOT NULL
);
```

用途：
- 保留 pull / push / ack / apple scan 的独立时间点
- 后续便于恢复、诊断和增量扫描

#### `reminder_task_mappings`

```sql
CREATE TABLE IF NOT EXISTS reminder_task_mappings (
    reminder_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL UNIQUE,
    reminder_external_identifier TEXT,
    reminder_list_identifier TEXT,
    reminder_fingerprint TEXT NOT NULL,
    backend_version_token TEXT NOT NULL,
    sync_state TEXT NOT NULL,
    synced_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_mappings_task_id ON reminder_task_mappings(task_id);
CREATE INDEX IF NOT EXISTS idx_mappings_sync_state ON reminder_task_mappings(sync_state);
```

用途：
- reminder ↔ task 的一对一映射
- 保存本地 fingerprint 和 backend version token
- 为 conflict / delete / ack 提供稳定依据

#### `pending_operations`

```sql
CREATE TABLE IF NOT EXISTS pending_operations (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    payload BLOB,
    status TEXT NOT NULL,
    last_error_message TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pending_operations_retry ON pending_operations(status, next_retry_at);
```

用途：
- 保存需要重试的 push / delete / local apply 失败操作
- 支持 retrying / failed / completed 等状态

#### `schema_migrations`

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);
```

用途：
- 明确 migration version
- 后续适配 GRDB / 原生 sqlite3 都方便

### 5.4.2 当前 Persistence 接口边界

当前 `BridgeStateStore` 协议已经补到接近真实实现所需：
- `loadConfiguration` / `saveConfiguration`
- `loadCheckpoint` / `saveCheckpoint`
- `loadMappings` / `saveMappings`
- `loadPendingOperations`
- `enqueuePendingOperations`
- `updatePendingOperations`
- `removePendingOperations`
- `exportSQLiteSchema`

这意味着未来换成 `SQLiteBridgeStateStore` 时，不需要再改 `BridgeCore` 依赖方向。

### 5.4.3 当前 SQLiteBridgeStateStore 落地状态（2026-03）

当前仓库已新增一版基于原生 `SQLite3` 的 `SQLiteBridgeStateStore`，定位是：

**不是最终工业级实现，但已经足够表达真实 bridge 状态如何落 SQLite。**

当前已具备：
- 自动创建数据库父目录
- 执行 schema 建表
- 在 `schema_migrations` 记录 `currentVersion`
- 初始化 `bridge_configuration` / `sync_checkpoint` 默认行
- `WAL` / `foreign_keys` 初始化
- 批量 mapping / pending operations 写入时使用 transaction
- `configuration` / `checkpoint` / `mappings` / `pending_operations` 的完整 load/save/upsert/remove

当前仍缺：
- 更正式的 migration graph（不仅是 currentVersion 打点）
- busy / locked 自动退避
- rollback / corruption 恢复
- tombstone 清理 / vacuum 策略
- 真机上的 durability 与并发验证

但从工程阶段看，它已经把 bridge 从“只有 schema 文档”推进到“可以开始真的把 state 落盘”。

## 5.5 BridgeCLI / BridgeApp
负责宿主入口：
- 前台运行
- 单次 sync 调试
- 输出日志
- 后续接 LaunchAgent

---

## 6. 本地数据模型

## 6.1 BridgeConfig

```json
{
  "bridge_id": "macbook-pro-001",
  "backend_base_url": "https://example.com",
  "api_token": "***",
  "poll_interval_seconds": 20,
  "apple_scan_window_seconds": 120,
  "enable_push_to_apple": true,
  "enable_pull_from_apple": true,
  "default_bucket_list_map": {
    "Inbox": "inbox",
    "Next": "next",
    "Waiting": "waiting",
    "Someday": "someday",
    "Projects": "project",
    "Done": "done"
  }
}
```

## 6.2 LocalCheckpoint

```json
{
  "backend_cursor": "cursor-123",
  "last_pull_cursor": "cursor-123",
  "last_push_cursor": "42",
  "last_acked_change_id": 42,
  "last_failed_change_id": null,
  "last_seen_change_id": 42,
  "last_successful_sync_at": "2026-03-19T00:00:00Z",
  "last_successful_pull_at": "2026-03-19T00:00:10Z",
  "last_successful_push_at": "2026-03-19T00:00:20Z",
  "last_successful_ack_at": "2026-03-19T00:00:30Z",
  "last_apple_scan_started_at": "2026-03-19T00:00:05Z",
  "last_sync_status": "success",
  "last_error_code": null,
  "last_error_message": null
}
```

## 6.3 ReminderTaskMapping

```json
{
  "task_id": "uuid",
  "apple_reminder_id": "EK_REMINDER_CALENDAR_ITEM_ID",
  "apple_calendar_id": "EKCalendar.calendarIdentifier",
  "apple_list_id": "EKCalendar.calendarIdentifier",
  "reminder_external_identifier": "EK_REMINDER_CALENDAR_ITEM_ID",
  "last_synced_task_version": 12,
  "last_seen_apple_modified_at": "2026-03-19T00:00:00Z",
  "last_pushed_fingerprint": "sha256:...",
  "sync_state": "active"
}
```

## 6.4 PendingOperation

```json
{
  "id": "uuid",
  "direction": "backend_to_apple",
  "kind": "update",
  "record_key": "task:uuid",
  "status": "retrying",
  "attempt": 3,
  "next_retry_at": "2026-03-19T00:10:00Z",
  "last_error": "eventkit_save_failed"
}
```

---

## 7. 同步状态机

## 7.1 顶层状态机

```text
Idle
  -> Bootstrapping
  -> Authorizing
  -> ScanningApple
  -> PullingToBackend
  -> FetchingBackendChanges
  -> ApplyingToApple
  -> AckingBackend
  -> PersistingCheckpoint
  -> Idle
```

出错时进入：

```text
AnyActiveState -> RecoverableError -> BackoffWait -> Idle
AnyActiveState -> FatalError -> RequiresOperatorAction
```

## 7.2 状态定义

### Idle
等待下一轮调度。

### Bootstrapping
初始化配置、日志、SQLite、bridge_id、HTTP client。

### Authorizing
检查 EventKit 授权状态：
- 未授权：请求授权
- 被拒绝：进入 `RequiresOperatorAction`
- 已授权：继续

### ScanningApple
扫描 Apple 侧变更，产出标准化 `AppleDelta[]`。

来源包括：
- 新建 reminder
- 标题 / note / due date 变更
- 完成状态变更
- list 变更
- 删除（需靠本地缓存 / 缺失检测辅助判断）

### PullingToBackend
调用 `POST /api/sync/apple/pull`，批量提交 Apple 侧变更。

### FetchingBackendChanges
调用 `POST /api/sync/apple/push` 拉后端待回写变更。

### ApplyingToApple
将 backend change 转换为 EventKit 写操作。

### AckingBackend
对成功写入 Apple 的变更调用 `ack`。

### PersistingCheckpoint
更新 checkpoint、mapping、失败队列、最近运行统计。

### RecoverableError
可重试错误：
- 网络超时
- 5xx
- EventKit 临时保存失败
- 本地数据库 busy

### FatalError / RequiresOperatorAction
不可自动恢复：
- EventKit 权限被拒绝
- config 丢失且无默认值
- token 无效且无法刷新
- 本地 schema 损坏

---

## 7.3 单条记录状态机

针对一条映射记录，建议维护以下局部状态：

```text
Unmapped
  -> DiscoveredFromApple
  -> CreatedInBackend
  -> Mapped
  -> Synced
  -> DirtyAppleSide
  -> Pulled
  -> DirtyBackendSide
  -> Pushed
  -> Synced
```

异常分支：

```text
Mapped -> Conflict
Mapped -> RetryPending
Mapped -> Tombstoned
```

说明：
- `Unmapped`: 本地尚无 mapping
- `DiscoveredFromApple`: 扫描发现 Reminder，但后端无 task_id
- `CreatedInBackend`: backend 接收后返回新的 task / mapping
- `Mapped`: 已建立双向映射
- `DirtyAppleSide`: Apple 端有本地修改待上送
- `DirtyBackendSide`: backend 返回待下发修改
- `Conflict`: 同字段双向冲突
- `RetryPending`: 某次同步失败待重试
- `Tombstoned`: 已删除但保留墓碑，避免重复创建

---

## 8. 同步流程

## 8.1 首次全量同步

首次启动时需要解决“已有 Apple reminders 如何进入主库”的问题。

### 推荐策略

1. 扫描指定同步列表中的所有 reminder
2. 对每个 reminder 生成标准化 payload
3. 调 `pull` 接口，附带 `is_initial_sync=true`
4. 后端：
   - 若已有 mapping，更新现有 task
   - 若无 mapping，新建 task + mapping
5. 保存本地 mapping snapshot
6. 拉一次 `push`，确保后端已有变更也能下发

### 不建议的行为
- 首次启动时直接盲目覆盖 Apple 端
- 仅凭标题模糊匹配强行合并任务

MVP 中如果没有稳定 ID 映射，就宁可新建 mapping，也不要做高风险智能合并。

---

## 8.2 Apple -> Backend 增量同步

桥需要周期扫描 Apple 侧变化。

### 变更来源
- `completionDate` 变化
- `title` 变化
- `notes` 变化
- `dueDateComponents` 变化
- `priority` 变化
- `calendar` 变化
- reminder 消失（可能是删除或移出同步范围）

### AppleDelta 标准结构

```json
{
  "apple_reminder_id": "xxx",
  "apple_list_id": "yyy",
  "title": "给客户回电话",
  "note": "讨论合同",
  "priority": 5,
  "due_at": "2026-03-20T14:00:00+08:00",
  "is_completed": false,
  "modified_at": "2026-03-19T00:00:00Z",
  "is_deleted": false
}
```

### 增量检测建议

MVP 可采用“窗口扫描 + 指纹比对”：
- 每轮读取所有同步列表中的 reminder
- 计算 fingerprint（title/note/due/completed/list/priority）
- 与本地缓存比较
- 差异即视为变更

优点：
- 不依赖 EventKit 是否提供稳定的 `lastModifiedDate` 语义
- 实现可控

代价：
- 扫描成本偏高，但在个人任务规模下可接受

---

## 8.3 Backend -> Apple 增量同步

后端返回 `changes[]`，桥逐条执行：

- `create`
- `update`
- `complete`
- `reopen`
- `delete`
- `move_list`

每条 change 处理后都要给出：
- success
- skipped
- conflict
- failed

成功后统一 ack；失败则落本地重试队列。

---

## 8.4 当前 planner / resolver 边界建议

当前 scaffold 已把主流程中的计划逻辑拆成：
- `PullPlanning`
- `PushPlanning`
- `ConflictResolving`
- `RetryScheduling`

建议继续保持以下职责边界：

### `SyncCoordinator`
只负责 orchestration：
- 调 store / client / reminder adapter
- 组装上下文
- 调 planner
- apply side effects
- persist checkpoint / mappings / pending queue

### `PullPlanner`
只负责 backend change → local action / conflict / ack 的计划计算，不直接写 EventKit。

### `PushPlanner`
只负责 reminder snapshot → remote mutation 的构建，不直接调 HTTP。

### `ConflictResolver`
只负责判断 `backendWins` / `reminderWins` / `manualReview`，不直接写存储。

### `RetryScheduler`
只负责 attempt → nextRetryAt 计算。

这样做的好处是：
- coordinator 不会继续膨胀
- 单测可以分别覆盖 pull / push 计划
- 后续字段级 merge、delete tombstone 规则能在 planner 层继续演化

---

## 9. 字段映射规则

## 9.1 支持的 MVP 字段

| Backend Task | Apple Reminder | 方向 | 说明 |
|---|---|---|---|
| `title` | `title` | 双向 | 主标题，直接映射 |
| `note` | `notes` | 双向 | 备注正文 |
| `due_at` | `dueDateComponents` | 双向 | 需处理时区与全天语义 |
| `priority` | `priority` | 双向 | 做有限值转换 |
| `status=completed` / `completed_at` | `isCompleted` / `completionDate` | 双向 | 完成时同步完成时间 |
| `bucket` | `calendar/list` | 双向 | 通过 list mapping 实现 |
| `deleted_at` | 删除 reminder | 双向 | 用墓碑避免反复重建 |

## 9.2 后端保留、不映射到 Apple 的字段

以下字段默认不写回 Reminder：
- `project_id`
- `tags`（除非未来用 Reminder 自带标签能力）
- `operation_logs`
- `version`（仅桥本地缓存）
- AI 解析元数据
- 对话上下文

## 9.3 bucket 与 Apple list 的映射

推荐优先使用“显式配置”，而不是硬编码列表名。

### 示例

| Apple List | Backend Bucket |
|---|---|
| Inbox | `inbox` |
| Next | `next` |
| Waiting | `waiting` |
| Someday | `someday` |
| Projects | `project` |
| Done | `done` |

### 规则

1. 如果 reminder 所在 list 在配置中可识别，则映射对应 bucket
2. 未识别 list：
   - 默认映射为 `inbox`
   - 并记录 `unmapped_list_warning`
3. backend 下发 `bucket` 时：
   - 若能找到对应 Apple list，则移动 reminder
   - 找不到则 fallback 到默认 list（建议 Inbox）

---

## 9.4 priority 映射建议

Apple Reminder priority 与业务优先级不完全等价，MVP 只做弱映射。

建议规则：

| Backend priority | Apple priority |
|---|---|
| `null` | `0` |
| `1` | `1` |
| `2` | `5` |
| `3` | `9` |

解释：
- backend 可以保留简单 1/2/3 语义
- Apple 使用其有限等级，不追求完全精确

---

## 9.5 due_at / 时区 / 全天任务

这是实现中的高风险点，必须明确定义。

### 原则

1. backend 内部统一存储 RFC3339 / UTC timestamp
2. Apple 侧使用 `DateComponents` 表达
3. 如果 reminder 没有具体时间，仅有日期：
   - backend 仍存 `due_at`
   - 但需额外标记 `is_all_day_due=true`（建议后端未来补字段）
4. 如果后端当前没有 `is_all_day_due`，MVP 可先退化为本地附加元数据，不向用户暴露

### 当前阻塞

现有 `tasks` 表未在 TECH_SPEC 中定义 `is_all_day_due`，这会导致：
- Apple 全天提醒写回后端时语义丢失
- 再下发回 Apple 可能变成具体时刻

建议后续尽快补：
- `is_all_day_due boolean`
- 可选 `source_timezone text`

---

## 10. 冲突策略

## 10.1 冲突定义

当以下条件同时成立时视为冲突：
- 同一 mapping 已存在
- Apple 与 backend 在同一同步窗口内都修改过
- 且修改的是同一逻辑字段

## 10.2 MVP 冲突分级

### A. 可自动合并
例如：
- Apple 改 `title`
- backend 改 `due_at`

处理：字段级 merge。

### B. 同字段冲突
例如：
- Apple 把标题改成 A
- backend 把标题改成 B

处理：`last-write-wins`，但要记录 conflict log。

### C. 删除冲突
例如：
- Apple 删除 reminder
- backend 刚修改 title

MVP 建议：
- 删除优先级高于普通编辑
- 但不要直接物理抹除 mapping
- 写 tombstone，并上报后端为 deleted / archived（按接口能力决定）

## 10.3 时间判断依据

优先顺序：
1. 后端 change 自带 `updated_at` / `version`
2. Apple `lastModifiedDate`（如果可稳定获取）
3. 本地扫描发现时间

如果 Apple 真实修改时间不可稳定取得，则采用：
- `scan_detected_at` 作为近似时间
- 保守执行 LWW

## 10.4 冲突落日志结构

```json
{
  "task_id": "uuid",
  "apple_reminder_id": "xxx",
  "field": "title",
  "apple_value": "A",
  "backend_value": "B",
  "resolution": "backend_wins",
  "resolved_at": "2026-03-19T00:00:00Z"
}
```

---

## 11. 删除与墓碑策略

删除是双向同步里最容易出事故的点，MVP 必须保守。

## 11.1 Apple 删除

如果某个已映射 reminder：
- 上一轮存在
- 本轮扫描不存在
- 且所在 list 仍处于同步范围

则判定为 `apple_deleted`。

桥应：
1. 生成删除 delta 上送后端
2. 本地 mapping 标记 `tombstoned`
3. 保留少量墓碑窗口（例如 30 天）

原因：
- 避免同 ID 消失后又被误识别成“新任务”
- 避免网络失败造成重复创建

## 11.2 Backend 删除

后端若下发 `delete`：
- 桥尝试删除对应 reminder
- 成功后 ack
- mapping 改为 `tombstoned`

### MVP 不建议
- 立即硬删除本地 mapping 记录

建议墓碑保留到清理任务定期回收。

---

## 12. 错误恢复与重试

## 12.1 错误分类

### A. 网络类
- DNS / TLS / timeout
- 5xx
- 临时 429

策略：指数退避重试。

### B. 鉴权类
- token 过期 / 无效
- bridge_id 未注册

策略：
- 标记为 `RequiresOperatorAction`
- 暂停 push/pull
- 仍可保留本地待上传变更

### C. EventKit 类
- 无权限
- save reminder 失败
- calendar 不存在

策略：
- 权限问题：阻塞并提示用户处理
- 目标 list 丢失：fallback 到默认 list + warning
- 单条写失败：记录 pending operation，下一轮重试

### D. 本地存储类
- SQLite locked
- schema mismatch
- 文件损坏

策略：
- 短期锁冲突可重试
- schema mismatch 走 migration
- 文件损坏需人工介入

---

## 12.2 重试队列设计

所有失败的“可重放操作”都进本地队列。

字段建议：
- op_id
- direction
- payload
- attempt_count
- first_failed_at
- last_failed_at
- next_retry_at
- terminal_failure

退避建议：
- 第 1 次：30 秒
- 第 2 次：2 分钟
- 第 3 次：10 分钟
- 第 4 次：30 分钟
- 之后封顶 2 小时

## 12.3 幂等性要求

桥对后端写接口要尽量传：
- stable reminder id
- bridge_id
- operation id / request id

这样即使重试，也不会无限重复创建任务。

---

## 13. 配置项设计

## 13.1 必选配置

| 配置项 | 说明 |
|---|---|
| `backend_base_url` | 后端地址 |
| `api_token` | 同步桥专用 token |
| `bridge_id` | 设备唯一 ID |
| `default_list_name` 或 `default_list_id` | fallback list |
| `poll_interval_seconds` | 轮询间隔 |

## 13.2 推荐配置

| 配置项 | 说明 |
|---|---|
| `list_bucket_mapping` | Apple list 与 bucket 映射 |
| `enable_pull_from_apple` | 是否启用 Apple -> backend |
| `enable_push_to_apple` | 是否启用 backend -> Apple |
| `log_level` | debug/info/warn/error |
| `max_batch_size` | 单次同步批量上限 |
| `retry_backoff_policy` | 重试策略 |
| `full_rescan_interval_minutes` | 定期全量兜底扫描 |

## 13.3 调试配置

| 配置项 | 说明 |
|---|---|
| `dry_run` | 不真正写 Apple / backend |
| `single_list_only` | 限制在一个 list 内调试 |
| `print_payloads` | 输出请求和映射详情 |
| `disable_deletes` | 临时禁用删除回写 |

---

## 14. EventKit 依赖与 macOS 限制

这是实现前必须明确的现实约束。

## 14.1 依赖

Bridge 将直接依赖：
- `EventKit`
- `Foundation`
- `OSLog`
- `SQLite` 封装（如 GRDB，或原生 SQLite.swift / 自己薄封装）

其中核心 Apple 侧能力来自：
- `EKEventStore`
- `EKReminder`
- `EKCalendar`

## 14.2 权限限制

macOS 访问 Reminders 需要用户授权。

影响：
- 首次启动必须触发授权
- 若用户拒绝，桥无法继续工作
- 权限被系统回收后，桥需要检测并进入阻塞态

## 14.3 平台限制

### A. 只能在 macOS 运行
本桥依赖本地 Apple 账户下的 Reminders 数据，不能部署在 Linux 服务器上代替。

### B. 依赖用户登录态与本机 iCloud 同步
如果：
- 用户未登录 iCloud
- Reminders 未开启同步
- 本机处于异常离线 / 账户失效状态

则桥拿到的数据可能不完整。

### C. EventKit 对“增量事件流”支持有限
Reminder 不像某些数据库那样天然提供稳定增量流。

因此 MVP 不能过度依赖系统推送式变更事件，必须保留：
- 周期扫描
- 指纹比对
- 全量兜底扫描

### D. 删除检测并非天然可靠
某个 reminder 消失，可能是：
- 真删除
- 被移到不在同步范围的 list
- iCloud 暂时未下发

因此删除判定必须谨慎，建议：
- 连续多轮缺失再确认
- 或结合上次所在 list / 本地缓存辅助判断

### E. 后台常驻能力受系统策略影响
如果未来做 App + LaunchAgent：
- 登录态、沙盒策略、签名、权限声明都会影响稳定运行
- MVP 先做开发者本地可跑版本，不要一开始被发布形态卡死

## 14.4 建议的产品限制说明

MVP 可在 README 中提前声明：
- 仅支持 macOS 作为同步桥宿主
- 依赖用户本机已开启 Reminders 与 iCloud 同步
- 初期对全天任务、复杂子任务、附件、标签不保证完全同步
- 删除同步采取保守策略，可能存在短延迟

---

## 15. 推荐 API 契约补充

为了让桥更好实现，建议后端接口补充以下字段。

## 15.1 `pull` 返回内容建议

```json
{
  "results": [
    {
      "apple_reminder_id": "xxx",
      "task_id": "uuid",
      "action": "created",
      "task_version": 3,
      "resolved_fields": {
        "bucket": "inbox"
      }
    }
  ],
  "conflicts": [],
  "server_time": "2026-03-19T00:00:00Z"
}
```

## 15.2 `push` 返回内容建议

```json
{
  "changes": [
    {
      "change_id": "chg_001",
      "task_id": "uuid",
      "apple_reminder_id": "xxx",
      "op": "update",
      "task_version": 4,
      "updated_at": "2026-03-19T00:00:00Z",
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

## 15.3 `ack` 请求建议

```json
{
  "bridge_id": "macbook-pro-001",
  "results": [
    {
      "change_id": "chg_001",
      "apple_reminder_id": "xxx",
      "status": "success",
      "applied_at": "2026-03-19T00:00:30Z"
    }
  ]
}
```

理由：
- bridge 需要 stable `change_id` 来避免重复 ack
- `task_version` 有助于 mapping 更新与冲突判断

---

## 16. 实现顺序建议

## 16.1 第一批先做

1. `BridgeConfig` / `CheckpointStore`
2. `EventKitAdapter` 只读 reminders
3. `HTTPClient` 只打通 pull/push/ack
4. `SyncCoordinator` 单轮串行同步
5. 指纹比对 + mapping 落地

### 16.1.1 当前仓库内已落地的 scaffold（2026-03）

`mac-sync-bridge/` 当前已经不是纯 README 骨架，已补到更接近真实接线的 scaffold：

- `BridgeModels/Models.swift`
  - 已定义 `ReminderRecord`、`BackendTaskRecord`、`ReminderTaskMapping`
  - 已定义 `SyncCheckpoint`、`PendingOperation`、`PushTaskMutation`、`SyncPlan`、`SyncRunReport`
  - 已补 `OperationStatus`、`PullPlanningContext`、`PushPlanningContext`
- `BridgeCore/Protocols.swift`
  - 已定义 `ConflictResolving`、`RetryScheduling`、`DateProviding`
  - 已进一步拆出 `PullPlanning` / `PushPlanning`
  - 已定义 `DefaultPullPlanner` / `DefaultPushPlanner`
  - 已定义 `SyncCoordinatorDependencies`
- `BridgeCore/SyncCoordinator.swift`
  - 已提供单轮同步主流程：load checkpoint → pull → plan → apply local → push → ack → persist checkpoint / mapping / retry queue
- `EventKitAdapter/ReminderStore.swift`
  - 已定义 `ReminderStore` 协议与 `InMemoryReminderStore`
  - 已补 `EventKitReminderStoreConfiguration` / `ReminderDTOConverting` / `EventKitReminderStore`
- `HTTPClient/BackendSyncClient.swift`
  - 已定义 `BackendSyncClient` 协议与 `InMemoryBackendSyncClient`
  - 已补 `URLSessionBackendSyncClient`、`BackendEndpointSet`、`BackendClientError`
- `Persistence/BridgeStateStore.swift`
  - 已定义 `BridgeStateStore` 协议、`BridgeConfiguration`
  - 已补 `SQLiteSchemaDefinition`、`SQLiteBridgeStateStore` 与 pending operation 更新/删除接口
- `BridgeCLI/main.swift`
  - 已支持 `doctor` / `sync-once` / `run` / `print-config`
- `Tests/BridgeCoreTests/SyncCoordinatorTests.swift`
  - 已覆盖最小 push / pull 主链路测试
  - 已补 rejected push → pending queue 测试

也就是说，下一阶段重点已经可以从“先搭骨架”切到：
- 在 macOS 上把 `ReminderStore` 真正接到 EventKit
- 把 `SQLiteBridgeStateStore` 在真机上编译并补强 locked/migration 细节
- 用真实后端 payload 校准 `URLSessionBackendSyncClient`
- 把 pending operation executor 从“已成型边界”继续推进成真正 delivery runner

## 16.2 第二批补齐

1. Reminder 写回
2. 重试队列消费器
3. 删除墓碑
4. LaunchAgent 安装脚本
5. 更详细日志 / metrics

## 16.3 第三批再考虑

1. 菜单栏 UI
2. 手动冲突处理界面
3. 更智能的增量检测
4. 签名 / 发布 / 安装器

---

## 17. 当前已知阻塞点

## 17.1 后端模型字段仍不够

至少还缺这些语义位：
- `is_all_day_due`
- 更明确的 `updated_at` / `version` 在同步接口中的返回约定
- 删除 / 归档的标准同步动作定义
- `change_id` 是否稳定可 ack

## 17.2 删除语义尚未完全定稿

需要进一步明确：
- Apple 删除是否映射为 backend `deleted`
- 还是 `archived`
- 是否允许恢复 tombstone

## 17.3 list / bucket 映射需要产品层确认

`Projects` 是一个 bucket，还是多个 Apple lists 的聚合？
这会直接影响：
- 一对一 list mapping
- 还是 list + note/tag 辅助编码

MVP 暂按：
- `Projects` 作为一个统一 bucket/list

## 17.4 EventKit 真实字段可用性需代码验证

需要在实现阶段尽快确认：
- `lastModifiedDate` 是否对 Reminder 读写足够稳定
- 删除检测最稳妥的本地策略
- 完成状态与完成时间在不同账户类型下的表现

## 17.5 当前 still-missing 的工程缺口

虽然 scaffold 更真实了，但真正可联调前还缺：
- pending operation 的消费执行器
- 配置装载（文件/Keychain/env）
- request/response contract 测试
- LaunchAgent / 常驻运行方式
- macOS 真机 build + integration 验证

其中最关键的是：
- 当前环境还没有对 `EventKitReminderStore` 和 `SQLiteBridgeStateStore` 做真机编译回归
- pending operation 现在已有消费/执行骨架，但还不是最终后台 delivery runner
- 现在的代码已经足够表达真实结构，但要成为“可联调版本”，还需要下一步在 macOS 上收口 API 可用性、payload 契约与行为差异

---

## 18. MVP 验收标准

满足以下条件即可认为同步桥 MVP 可联调：

1. macOS 上能成功获得 Reminders 权限
2. 能扫描指定 Apple lists 中的 reminders
3. 首次全量同步可创建 backend task 与 mapping
4. Apple 修改标题 / note / due / completion 后，30 秒内可上送 backend
5. backend 下发标题 / note / due / completion / bucket 变更后，30 秒内可回写 Apple
6. 网络失败后可自动重试
7. 失败不会导致重复创建大量任务
8. 有基本日志与 checkpoint 可排查

---

## 19. 结论

Mac Sync Bridge 的 MVP 应该被实现为：

**一个运行在 macOS 上、以 EventKit 为本地源、以 SQLite 为状态缓存、以轮询 + 指纹比对为主、以稳定恢复优先的同步代理。**

第一阶段重点不是“优雅”，而是：
- 可跑通
- 可恢复
- 不乱写
- 不重复创建
- 能为后续产品化形态留接口

而以当前仓库状态看，bridge 已经明显越过“只有文档和假实现”的阶段，进入：
- EventKit adapter 真实结构已落地
- SQLite state store 真实结构已落地
- 下一步主要是 macOS 真机编译、行为校准、后端 contract 联调
