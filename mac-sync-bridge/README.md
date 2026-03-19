# mac-sync-bridge

Mac Sync Bridge 是 GTD 系统的本地同步代理，负责在：
- Apple Reminders（通过 EventKit）
- GTD Backend（通过 HTTPS API）

之间执行双向同步。

当前目录已经从“纯 README 骨架”推进到“更真实的可继续实现 scaffold”：
- SwiftPM target 已可 build（在 macOS/Swift 环境）
- 核心领域模型、协议、协调器骨架已落地
- `HTTPClient` 已开始向当前 backend 的 `/api/sync/apple/*` payload 靠拢
- `Persistence` 已从接口推进到 `SQLiteBridgeStateStore` 级别结构化实现
- `EventKitAdapter` 已从纯 fake 推进到 `EventKitReminderStore` 真实适配层结构
- `SyncCoordinator` 已补到 pending operation 消费/执行边界
- CLI 可跑 `doctor` / `sync-once` / `print-config`
- `BridgeCoreTests` 已覆盖最小 push / pull 主链路、rejected push retry queue、pending replay 消费骨架

它还不是可直接联调完成版，但相比纯 in-memory scaffold，已经更接近“真实可接 API / SQLite / EventKit”的状态。

## 这轮新增推进

### 1. Backend contract 对齐进一步前进

`BridgeModels` / `HTTPClient` 现在不再只围绕一个理想化的 `changes` 数组转：

- `PullChangesRequest` 已贴近 backend：
  - `bridgeID`
  - `cursor`
  - `limit`
  - `localChanges`（对应 backend 的 Apple pull input）
- `PushChangesRequest` 已贴近 backend：
  - `bridgeID`
  - `cursor`
  - `tasks: [{taskID, version}]`
  - `limit`
- `AckRequest` 已贴近 backend：
  - `bridgeID`
  - `acknowledgements: [AckItem]`
- `BackendTaskRecord` 已带上更多 bridge 真正需要保留的字段：
  - `remindAt`
  - `isAllDayDue`
  - `priority`
  - `listName`
  - `changeID`
  - `sourceRecordID` / `sourceListID` / `sourceCalendarID`

`URLSessionBackendSyncClient` 也已经开始把 backend 当前真实返回：
- pull 的 `accepted/applied/results/checkpoint`
- push 的 `mode/items/checkpoint`
- ack 的 `success/checkpoint`

转换成 bridge 内部模型，而不是继续假设“后端正好长成内部 DTO 的样子”。

### 2. SQLite checkpoint 更接近 bridge runtime

`SyncCheckpoint` / `sync_checkpoint` 表这轮新增了更贴近 backend delivery 状态的字段：
- `last_pull_cursor`
- `last_push_cursor`
- `last_acked_change_id`
- `last_failed_change_id`
- `last_seen_change_id`
- `last_error_code`
- `last_error_message`

`SQLiteBridgeStateStore` 现在不仅能保存“最近一次成功时间”，还开始能表达：
- 拉取推进到哪里
- 推送推进到哪里
- ack 到了哪条 change
- 最近失败点位与错误信息

这让后续 retry / replay / 断点续传更容易继续落地。

### 3. pending operation executor 边界已落清

`BridgeCore` 新增：
- `PendingOperationExecuting`
- `PendingExecutionResult`
- `DefaultPendingOperationExecutor`
- `NoopPendingOperationExecutor`

`SyncCoordinator.runSync()` 现在会在主同步前：
1. 读取 pending operations
2. 交给 executor 过滤到期任务并尝试 replay
3. 删除已完成项
4. 回写 retrying / failed 的更新状态

这还不是完整工业级 retry runner，但已经把最重要的边界定住：
- coordinator 负责 orchestration
- executor 负责执行 pending payload
- state store 负责 queue 状态持久化

后续如果要做后台定时 runner / LaunchAgent 循环执行，就不需要再推翻这层拆分。

### 4. EventKit adapter 再往真实行为收一点

`ReminderStore` 协议新增：
- `fetchReminderLists()`

`EventKitReminderStore` 继续贴近真机行为：
- 可真实枚举可同步 reminder lists
- due date 写回时开始区分“全天日期”与“带时间日期”的组件写法
- in-memory store 也同步补齐 list 枚举接口，方便 bridge/core 测试走同一边界

这能让 bridge 在 doctor / runtime 配置阶段更容易做：
- list 发现
- list mapping 验证
- 默认 list fallback

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

## 本地验证

在 `mac-sync-bridge/` 目录下：

```bash
swift build
swift test
swift run bridge-cli doctor
swift run bridge-cli sync-once
```

> 当前这个 Linux 容器里没有安装 `swift`，所以这轮只能完成代码推进、测试补充与文档对齐，无法在此处真正执行 Swift 编译回归。下一步需要在 macOS 开发机上做真机编译验证。

## 离真机联调还差什么

最关键的缺口已经从“没有结构”收缩到“需要真机/API 收口”：

1. **pending replay 仍是 executor 骨架，不是最终 delivery runner**
   - 当前已落边界，但还没做：
   - 分 operation kind 的完整执行器
   - ack/replay 结果与 mapping/checkpoint 的更细粒度联动
   - 后台常驻 runner / LaunchAgent 调度

2. **HTTP client 仍需在真实 backend 上逐字段校准**
   - 当前已对齐到 backend 现有 payload 方向
   - 但还需要真接口回归确认：
   - push item / pull result 的最终字段稳定性
   - reject / partial failure 的正式返回体
   - cursor / change_id / version 的最终契约

3. **EventKit 还缺真机行为验证**
   - 提醒事项 completion / dueDate / timezone / list 切换
   - 删除检测策略
   - 不同 Reminders 账户类型（iCloud / 本地 / Exchange）的字段表现

4. **SQLite migration 仍是单版本 seed 级别**
   - 现在 checkpoint 字段已更真实
   - 但还没补正式 migration graph / 版本升级脚本 / locked busy retry / corruption recovery

## 推荐下一步

如果下一轮继续推进，优先级建议：
1. 在 macOS 上跑通 `swift build && swift test`
2. 给 `URLSessionBackendSyncClient` 加 contract tests（mock JSON fixtures）
3. 把 pending executor 分裂成 remote push replay / local write replay 两类
4. 让 CLI / App 真正加载 SQLite 路径、bridge_id、backend token、default list 配置
5. 做第一次真机 EventKit 联调记录
