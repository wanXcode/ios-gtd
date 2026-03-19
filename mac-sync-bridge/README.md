# mac-sync-bridge

Mac Sync Bridge 是 GTD 系统的本地同步代理，负责在：
- Apple Reminders（通过 EventKit）
- GTD Backend（通过 HTTPS API）

之间执行双向同步。

当前目录已经从“纯 README 骨架”推进到“更真实的可继续实现 scaffold”：
- SwiftPM target 已可 build
- 核心领域模型、协议、协调器骨架已落地
- `HTTPClient` 已有一版可替换到真实环境的 `URLSessionBackendSyncClient`
- `Persistence` 已明确 SQLite schema 草案与 store 接口
- `SyncCoordinator` 已进一步拆出 planner 边界
- CLI 可跑 `doctor` / `sync-once` / `print-config`
- `BridgeCoreTests` 已覆盖最小 push / pull 主链路

它还不是可直接联调完成版，但相比纯 in-memory scaffold，已经更接近“真实可接 API / SQLite / EventKit”的状态。

## 目标

- 运行在 macOS
- 读取 / 写入 Apple Reminders
- 维护本地 mapping、checkpoint、重试队列
- 与后端执行 pull / push / ack

详细设计见：
- `../docs/SYNC_BRIDGE_SPEC.md`

## 当前代码结构

```text
mac-sync-bridge/
  Package.swift
  README.md
  Sources/
    BridgeApp/
      main.swift
      README.md
    BridgeCLI/
      main.swift
      README.md
    BridgeModels/
      Models.swift
    BridgeCore/
      Protocols.swift
      SyncCoordinator.swift
      README.md
    EventKitAdapter/
      ReminderStore.swift
      README.md
    HTTPClient/
      BackendSyncClient.swift
      README.md
    Persistence/
      BridgeStateStore.swift
      README.md
  Tests/
    BridgeCoreTests/
      SyncCoordinatorTests.swift
      README.md
```

## 已落地的核心模块

### BridgeModels
当前已经有共享领域模型：
- `ReminderRecord`
- `BackendTaskRecord`
- `ReminderTaskMapping`
- `SyncCheckpoint`
- `PendingOperation`
- `PushTaskMutation`
- `PullPlanningContext` / `PushPlanningContext`
- `SyncPlan`
- `SyncRunReport`

补充后的模型比之前更贴近真实落地：
- `ReminderTaskMapping` 带上 `reminderExternalIdentifier` / `reminderListIdentifier` / `syncState`
- `SyncCheckpoint` 不再只保留一个时间点，而是把 pull / push / ack / apple scan 的时间分开
- `PendingOperation` 增加 `status` / `lastErrorMessage`

这样 `EventKitAdapter` / `HTTPClient` / `Persistence` 不需要反向依赖 `BridgeCore`，避免模块循环。

### BridgeCore
当前已经有：
- `ConflictResolving` / `RetryScheduling` / `DateProviding`
- `PullPlanning` / `PushPlanning`
- `DefaultPullPlanner` / `DefaultPushPlanner`
- `SyncCoordinator`

当前 `SyncCoordinator` 已具备的主流程：
1. 读取 checkpoint / mapping / reminders
2. 从 backend `pullChanges`
3. 交给 pull planner / push planner 构建 sync plan
4. 应用本地 upsert / delete
5. 将本地变更 `pushChanges`
6. 持久化 mapping
7. 执行 `ackChanges`
8. 更新 checkpoint
9. 对 rejected mutation 进入 pending queue

现在 coordinator 不再独占所有计划逻辑，后续更适合把：
- 字段级 merge
- tombstone 策略
- 手动冲突处理

继续拆到独立 planner / resolver 中。

### EventKitAdapter
当前还是替身实现：
- `ReminderStore` 协议
- `ReminderAuthorizationStatus`
- `InMemoryReminderStore`

这让 `BridgeCore` 可以在不接真实 EventKit 的情况下先测试同步主链路。

### HTTPClient
当前不再只有 fake：
- `BackendSyncClient` 协议
- `BackendClientConfiguration`
- `BackendEndpointSet`
- `URLSessioning`
- `URLSessionBackendSyncClient`
- `InMemoryBackendSyncClient`

`URLSessionBackendSyncClient` 已经具备：
- base URL + token + timeout
- endpoint path 配置
- JSON encode / decode
- Authorization header
- HTTP status code 校验
- 明确的错误类型 `BackendClientError`

也就是说，后续只要 backend API payload 最终定稿，就可以直接拿这层接真实接口，而不是重写整套 client abstraction。

### Persistence
当前不再只有“存一下数组”的概念：
- `BridgeConfiguration`
- `BridgeStateStore` 协议
- `SQLiteSchemaDefinition`
- `InMemoryBridgeStateStore`

`BridgeStateStore` 已明确支持：
- load / save configuration
- load / save checkpoint
- load / save mappings
- enqueue / update / remove pending operations
- export SQLite schema

`SQLiteSchemaDefinition` 已给出一版可直接转成 migration 的 SQL 草案，覆盖：
- `bridge_configuration`
- `sync_checkpoint`
- `reminder_task_mappings`
- `pending_operations`
- `schema_migrations`

这意味着后续接 GRDB / SQLite 时，不需要再从零想 checkpoint/mapping/pending queue 怎么落表。

### BridgeCLI
当前支持：
- `bridge-cli doctor`
- `bridge-cli sync-once`
- `bridge-cli run`
- `bridge-cli print-config`

目前命令仍使用内建 fixture 依赖，主要用于验证结构与流程，不代表最终配置加载方式。

## 本地验证

在 `mac-sync-bridge/` 目录下：

```bash
swift build
swift test
swift run bridge-cli doctor
swift run bridge-cli sync-once
```

如果当前环境缺 Swift 或 FoundationNetworking / URLSession 行为受平台限制，可以先把它视为“高质量 scaffold”，后续在 macOS 开发机上继续编译联调。

## 距离真正可联调，还差什么

最关键的缺口还在这几项：

1. **真实 EventKit 实现**
   - `EKEventStore` 授权
   - reminder 查询
   - reminder save/delete
   - DTO 与 EventKit 对象转换

2. **真实 SQLite store**
   - 基于 `SQLiteSchemaDefinition` 做 migration
   - 把 `BridgeStateStore` 换成 `SQLiteBridgeStateStore`
   - 处理 busy / transaction / WAL / corruption 恢复

3. **和后端 contract 对齐**
   - pull/push/ack 的 payload 是否与当前 `BridgeModels` 一致
   - `cursor` / `change_id` / `versionToken` 语义最终定稿
   - rejected / partial success 的返回结构细化

4. **重试与恢复继续补完整**
   - pending queue 的消费执行器
   - retry / terminal failure / dead-letter 策略
   - ack 幂等与重复 push 去重

5. **删除墓碑与缺失检测**
   - Apple 删除如何确认
   - mapping tombstone 保留多久
   - 何时允许真正清理

6. **宿主与运行方式**
   - LaunchAgent
   - 常驻进程与日志
   - 配置来源（文件 / Keychain / env）

## 当前刻意没做的部分

这些仍然是空白或半成品：
- 真实 EventKit 读写
- 真实 SQLite 落盘
- pending operation 的实际执行循环
- LaunchAgent / 菜单栏宿主
- 完整删除墓碑恢复策略
- 全天任务 / 时区语义精确处理
- 更细粒度冲突日志与人工处理入口
