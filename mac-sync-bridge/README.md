# mac-sync-bridge

Mac Sync Bridge 是 GTD 系统的本地同步代理，负责在：
- Apple Reminders（通过 EventKit）
- GTD Backend（通过 HTTPS API）

之间执行双向同步。

当前目录已经从“纯 README 骨架”推进到“可编译 scaffold”：
- SwiftPM target 已可 build
- 核心领域模型、协议、协调器骨架已落地
- 提供 in-memory `ReminderStore` / `BackendSyncClient` / `BridgeStateStore`
- CLI 可跑 `doctor` / `sync-once` / `print-config`
- `BridgeCoreTests` 已覆盖最小 push / pull 主链路

它还不是可接真实 EventKit / 真实 HTTP / 真实 SQLite 的完成版，但模块边界、流程入口、状态载体已经更清楚，后续可以直接往真实实现替换。

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
- `SyncPlan`
- `SyncRunReport`

这样 `EventKitAdapter` / `HTTPClient` / `Persistence` 不需要反向依赖 `BridgeCore`，避免模块循环。

### BridgeCore
当前已经有：
- `ConflictResolving` / `RetryScheduling` / `DateProviding`
- `SyncCoordinator`

当前 `SyncCoordinator` 已具备的主流程：
1. 读取 checkpoint / mapping / reminders
2. 从 backend `pullChanges`
3. 构建 sync plan
4. 应用本地 upsert / delete
5. 将本地变更 `pushChanges`
6. 持久化 mapping
7. 执行 `ackChanges`
8. 更新 checkpoint
9. 对 rejected mutation 进入 pending queue

### EventKitAdapter
当前还是替身实现：
- `ReminderStore` 协议
- `ReminderAuthorizationStatus`
- `InMemoryReminderStore`

这让 `BridgeCore` 可以在不接真实 EventKit 的情况下先测试同步主链路。

### HTTPClient
当前还是替身实现：
- `BackendSyncClient` 协议
- `BackendClientConfiguration`
- `InMemoryBackendSyncClient`

后续替换成真实 URLSession 客户端时，尽量保持协议不变。

### Persistence
当前还是替身实现：
- `BridgeConfiguration`
- `BridgeStateStore` 协议
- `InMemoryBridgeStateStore`

后续可把这个 actor 替换为 SQLite / GRDB 实现，不影响 `BridgeCore` 的调度逻辑。

### BridgeCLI
当前支持：
- `bridge-cli doctor`
- `bridge-cli sync-once`
- `bridge-cli run`
- `bridge-cli print-config`

目前命令使用内建 fixture 依赖，主要用于验证结构与流程，不代表最终配置加载方式。

## 本地验证

在 `mac-sync-bridge/` 目录下：

```bash
swift build
swift test
swift run bridge-cli doctor
swift run bridge-cli sync-once
```

## 下一步最值得做的事

1. **接真实 EventKit**
   - `EKEventStore` 授权
   - reminder 查询
   - reminder save/delete
   - 标准 DTO 与 EventKit 对象双向转换

2. **接真实 HTTP 客户端**
   - URLSession
   - `/api/sync/apple/pull`
   - `/api/sync/apple/push`
   - `/api/sync/apple/ack`
   - token / timeout / retry / error mapping

3. **接真实 Persistence**
   - GRDB 或 SQLite
   - config/checkpoint/mappings/pending_operations 表
   - migration

4. **把计划逻辑拆细**
   - Pull planner / Push planner / Conflict resolver 单独类型化
   - 删除墓碑策略
   - 字段级 merge

5. **补端到端 contract**
   - 和 backend 同步接口字段完全对齐
   - 明确 `versionToken` / `change_id` / cursor 语义

## 当前刻意没做的部分

这些仍然是空白或半成品：
- 真实 EventKit 读写
- 真实 URLSession 网络调用
- SQLite 落盘
- LaunchAgent / 菜单栏宿主
- 完整删除墓碑恢复策略
- 全天任务 / 时区语义精确处理
- 更细粒度冲突日志与人工处理入口
