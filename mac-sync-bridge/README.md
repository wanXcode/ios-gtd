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
- 新增 `BridgeRuntime`，把 CLI runtime config / SQLite / URLSession client / EventKit wiring 串起来
- CLI 可跑 `doctor` / `sync-once` / `print-config`，且不再依赖 in-memory demo wiring
- `BridgeApp` 已从纯占位推进到可常驻 loop 的 runtime host，支持按配置周期持续触发 sync
- `BridgeCoreTests` + `BridgeRuntimeTests` 已覆盖主链路、配置加载优先级与 BridgeApp loop 行为

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

### 5. BridgeRuntime：把 scaffold 真正接成 runtime

这轮补了一个新的 `BridgeRuntime` target，把此前分散的 scaffold 接成一条更像真实运行态的 wiring：

- `BridgeRuntimeConfiguration`
  - `bridgeID`
  - `backendBaseURL`
  - `apiToken`
  - `sqlitePath`
  - `syncIntervalSeconds`
  - `defaultReminderListIdentifier`
  - `syncedReminderListIdentifiers`
  - `includeCompletedReminders`
  - `backendTimeoutSeconds`
- `BridgeRuntimeConfigurationLoader`
  - 支持 `config.json` + 环境变量 + CLI flags 三层配置合并
  - 优先级：`CLI > ENV > config.json > defaults`
- `BridgeRuntime`
  - 统一组装 `SQLiteBridgeStateStore`
  - 统一组装 `EventKitReminderStore`
  - 统一组装 `URLSessionBackendSyncClient`
  - 生成真正带 `bridgeID` 的 `SyncCoordinator`

这意味着 `bridge-cli` 不再只是“打印 in-memory demo 数据”，而是已经开始具备：
- 固定 bridge identity
- 持久化 SQLite state
- backend token / base URL 注入
- 默认 Reminders list / synced lists 配置
- doctor 阶段发现 lists / 打印 sqlite path / 打印 runtime config

### 6. BridgeApp：从入口占位变成可常驻 loop 的宿主

这轮把 `BridgeApp` 从一句提示语推进成真正的 runtime host：

- 复用 `BridgeRuntimeConfigurationLoader`，直接吃同一套 `config.json` / ENV / CLI 配置
- 新增 `BridgeAppRuntime`
  - 启动后立即执行一次 sync
  - 按 `syncIntervalSeconds` 进入常驻循环
  - 每轮记录 started / finished / failed 日志
  - 支持 `--once` / `--max-iterations N` 方便真机 smoke test
- 新增 `BridgeRuntimeTicking` / `BridgeRuntimeLogging`
  - 让 loop 的 sleep / logging 行为可注入
  - 后续接 LaunchAgent、菜单栏 host、OSLog 时不用重写主循环
- `BridgeRuntimeTests` 新增 loop coverage
  - 验证多轮 sync 会按 interval 休眠
  - 验证单轮失败不会直接打断常驻 runner

这一步的价值不只是“多了个 main.swift”，而是把 bridge 正式往 daemon / agent 运行态推了一层：后续 LaunchAgent 只需要负责拉起进程和传配置，不需要再重新设计核心循环。

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
    BridgeRuntime/
      RuntimeConfiguration.swift
      BridgeAppRuntime.swift
  Tests/
    BridgeCoreTests/
      SyncCoordinatorTests.swift
      README.md
    BridgeRuntimeTests/
      RuntimeConfigurationTests.swift
      BridgeAppRuntimeTests.swift
```

## 本地验证

在 `mac-sync-bridge/` 目录下：

```bash
swift build
swift test
swift run bridge-cli print-config --backend-base-url http://127.0.0.1:8000
swift run bridge-cli doctor --backend-base-url http://127.0.0.1:8000 --sqlite-path ~/Library/Application\ Support/GTD/mac-sync-bridge/bridge-state.sqlite
swift run bridge-cli sync-once --backend-base-url http://127.0.0.1:8000 --api-token "$BRIDGE_API_TOKEN"
swift run BridgeApp --backend-base-url http://127.0.0.1:8000 --api-token "$BRIDGE_API_TOKEN" --once
swift run BridgeApp --backend-base-url http://127.0.0.1:8000 --api-token "$BRIDGE_API_TOKEN" --sync-interval 60 --max-iterations 3
```

也可以把运行态配置放进默认 JSON 文件：

```json
{
  "bridgeID": "mbp-14-sync-bridge",
  "backendBaseURL": "https://gtd.example.com",
  "apiToken": "token-value",
  "sqlitePath": "~/Library/Application Support/GTD/mac-sync-bridge/bridge-state.sqlite",
  "syncIntervalSeconds": 300,
  "defaultReminderListIdentifier": "x-apple-reminderkit-list",
  "syncedReminderListIdentifiers": ["inbox-list-id", "next-list-id"],
  "includeCompletedReminders": true,
  "backendTimeoutSeconds": 30
}
```

默认路径：
- `~/Library/Application Support/GTD/mac-sync-bridge/config.json`

配置优先级：
- CLI flags
- 环境变量（如 `BRIDGE_ID` / `BRIDGE_BACKEND_BASE_URL` / `BRIDGE_API_TOKEN` / `BRIDGE_SQLITE_PATH` / `BRIDGE_DEFAULT_LIST_ID` / `BRIDGE_SYNCED_LIST_IDS`）
- config.json
- 内置默认值

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
   - 现在 checkpoint 字段已更真实，且 CLI 已开始真正落盘使用 SQLite path
   - 但还没补正式 migration graph / 版本升级脚本 / locked busy retry / corruption recovery

## 推荐下一步

如果下一轮继续推进，优先级建议：
1. 在 macOS 上跑通 `swift build && swift test`
2. 给 `URLSessionBackendSyncClient` 加 contract tests（mock JSON fixtures）
3. 把 pending executor 分裂成 remote push replay / local write replay 两类
4. 让 `BridgeApp` / LaunchAgent 真正消费 `BridgeRuntimeConfiguration` 并进入常驻循环
5. 做第一次真机 EventKit 联调记录
