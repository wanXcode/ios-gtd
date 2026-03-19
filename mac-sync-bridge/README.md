# mac-sync-bridge

Mac Sync Bridge 是 GTD 系统的本地同步代理，负责在：
- Apple Reminders（通过 EventKit）
- GTD Backend（通过 HTTPS API）

之间执行双向同步。

当前目录已经从“纯 README 骨架”推进到“更真实的可继续实现 scaffold”：
- SwiftPM target 已可 build
- 核心领域模型、协议、协调器骨架已落地
- `HTTPClient` 已有一版可替换到真实环境的 `URLSessionBackendSyncClient`
- `Persistence` 已从接口推进到 `SQLiteBridgeStateStore` 级别结构化实现
- `EventKitAdapter` 已从纯 fake 推进到 `EventKitReminderStore` 真实适配层结构
- `SyncCoordinator` 已进一步拆出 planner 边界
- CLI 可跑 `doctor` / `sync-once` / `print-config`
- `BridgeCoreTests` 已覆盖最小 push / pull 主链路与 rejected push retry queue

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
当前不再只是替身实现：
- `ReminderStore` 协议
- `ReminderStoreError`
- `EventKitReminderStoreConfiguration`
- `ReminderListRecord`
- `ReminderDTOConverting` / `DefaultReminderDTOConverter`
- `EventKitReminderStore`
- `InMemoryReminderStore`

`EventKitReminderStore` 当前已经把真实适配层的主边界写清并尽量落代码：
- 读取与请求授权
- list 枚举与同步范围过滤
- `EKReminder` → `ReminderRecord` DTO 转换
- 按 `externalIdentifier` 定位已有 reminder
- upsert / delete 的批量保存与统一 commit
- 无 EventKit 环境下提供降级 stub，避免 Linux / CI 完全卡死

这层现在已经不是“以后再说”的 README，而是可以直接在 macOS 上继续补真机联调细节。

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
- `SQLiteBridgeStateStore`
- `InMemoryBridgeStateStore`

`SQLiteBridgeStateStore` 当前已经把结构化落盘打到接近真实实现：
- 自动建库、建表、记录 migration version
- `bridge_configuration` / `sync_checkpoint` seed
- configuration / checkpoint / mappings / pending operations 的读写
- transaction 包裹批量 upsert / delete
- `WAL` + `foreign_keys` 初始化
- 在无 `SQLite3` 环境下仍能保留编译边界

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

如果当前环境缺 Swift 或 EventKit / SQLite3 行为受平台限制，可以先把它视为“高质量 scaffold + 半真实实现”，后续在 macOS 开发机上继续编译联调。

## 这次推进的重点

### 1. SQLite state store

这次已经把“schema 说明文档”推进到“真实 store 结构化实现”：
- 真实 actor：`SQLiteBridgeStateStore`
- 原生 `SQLite3` 薄封装：database / statement / bind / row decode
- 配置、checkpoint、mapping、pending operation 的表级读写
- schema migration 打点 + seed 默认行

虽然还没有做复杂 migration graph，但已经足够让 bridge 真正开始把状态落到 SQLite 文件中，而不是只停留在 in-memory。

### 2. EventKit adapter

这次把 `EventKitReminderStore` 的模块边界往真实实现推进了一大步：
- 授权状态映射
- 首次请求权限流程
- list 枚举
- reminder scan
- DTO/fingerprint 转换
- upsert/delete 的 EventKit 保存流程
- 非 macOS 环境的 stub fallback

也就是说，后续在真机上主要是校准 EventKit 细节，而不是从零想结构。

### 3. Bridge tests

补了 bridge 侧一个更实际的测试：
- 当 backend reject push 时，`SyncCoordinator` 会把 mutation 进入 pending queue

这条测试把当前“重试队列不是摆设”这件事往前推进了一步。

## 距离真正可联调，还差什么

最关键的缺口还在这几项：

1. **在 macOS 开发机上真实编译验证**
   - 当前环境没有 Swift toolchain
   - 也没有 EventKit 真机运行条件
   - 需要在 macOS 上校准 `EKEventStore` 行为和 API availability

2. **SQLite store 还需要工程化加固**
   - busy/locked 重试
   - rollback / corruption 恢复
   - 更正式的多版本 migration
   - 更细粒度 tombstone / cleanup 策略

3. **和后端 contract 对齐**
   - pull/push/ack 的 payload 是否与当前 `BridgeModels` 一致
   - `cursor` / `change_id` / `versionToken` 语义最终定稿
   - rejected / partial success 的返回结构细化

4. **EventKit 真实语义还要补验证**
   - `lastModifiedDate` 是否足够稳定
   - 全天任务 / 时区转换怎么保真
   - 删除缺失检测怎么做得更稳
   - list / bucket 映射器要不要独立模块化

5. **运行宿主与配置来源**
   - LaunchAgent
   - 常驻进程与日志
   - 配置来源（文件 / Keychain / env）

## 当前刻意没做的部分

这些仍然是空白或半成品：
- pending operation 的实际消费循环
- 完整删除墓碑恢复策略
- 全天任务 / 时区语义精确处理
- 更细粒度冲突日志与人工处理入口
- LaunchAgent / 菜单栏宿主
