# mac-sync-bridge

`mac-sync-bridge` 是 GTD 系统的 macOS 本地同步代理，负责在以下两端之间做同步：

- Apple Reminders（通过 EventKit）
- GTD Backend（通过 `/api/sync/apple/*` HTTPS API）

它的目标不是替代后端，而是作为一层运行在用户 Mac 本机的桥接器，把本地 Reminder 的新增/变更安全地推送到 backend，并消费 backend 下发给 Apple 侧的同步任务。

---

## 当前状态

这套 bridge 已经完成首轮真实联调闭环，目标 backend 为：

- `https://gtd.5666.net`

真实验证结果已经确认：

- Apple Reminders 新建提醒可以经 `mac-sync-bridge` 首次 create push 成功写入 backend
- backend 会正确返回 accepted
- bridge 能正确统计 `report_pushed`
- bridge 能正确做 ack 并统计 `report_acked`
- accepted 结果能正确映射回对应的 reminderID（不会再错配到旧 reminder）

### 已验证通过的关键链路

- EventKit 抓取本地 reminders ✅
- planner 生成 create mutations ✅
- bridge push request 组装 ✅
- backend `/api/sync/apple/push` create contract ✅
- backend 创建 task 与 mapping ✅
- push accepted 解码 ✅
- accepted → reminderID 正确回填 ✅
- ack 回写 ✅

---

## 目录结构

```text
mac-sync-bridge/
  Package.swift
  README.md
  Sources/
    BridgeApp/
      main.swift
    BridgeCLI/
      main.swift
    BridgeModels/
      Models.swift
    BridgeCore/
      Protocols.swift
      SyncCoordinator.swift
    EventKitAdapter/
      ReminderStore.swift
    HTTPClient/
      BackendSyncClient.swift
    Persistence/
      BridgeStateStore.swift
    BridgeRuntime/
      RuntimeConfiguration.swift
      BridgeAppRuntime.swift
  Tests/
    BridgeCoreTests/
      SyncCoordinatorTests.swift
    BridgeRuntimeTests/
      RuntimeConfigurationTests.swift
      BridgeAppRuntimeTests.swift
    HTTPClientTests/
      URLSessionBackendSyncClientContractTests.swift
  config/
    config.example.json
  launchd/
    com.iosgtd.syncbridge.plist
  scripts/
    install_launch_agent.sh
```

---

## 本地配置

推荐使用 JSON 配置文件。

示例：

```json
{
  "bridgeID": "wan-macbook",
  "backendBaseURL": "https://gtd.5666.net",
  "apiToken": "YOUR_TOKEN",
  "sqlitePath": "/Users/wan/workspace/ios-gtd/mac-sync-bridge/bridge-state.sqlite",
  "syncIntervalSeconds": 30,
  "defaultReminderListIdentifier": "AC5C2C43-4F4E-4040-8CE9-F247DC1B268F",
  "syncedReminderListIdentifiers": [
    "AC5C2C43-4F4E-4040-8CE9-F247DC1B268F"
  ],
  "includeCompletedReminders": true,
  "backendTimeoutSeconds": 30
}
```

### 当前真实联调中使用的关键信息

- backend: `https://gtd.5666.net`
- bridge_id: `wan-macbook`
- sqlite: `/Users/wan/workspace/ios-gtd/mac-sync-bridge/bridge-state.sqlite`
- 测试列表：`GTD Sync Test`
- 测试列表 ID：`AC5C2C43-4F4E-4040-8CE9-F247DC1B268F`

---

## CLI 命令

### 打印当前配置

```bash
swift run bridge-cli print-config --config ./config/config.local.json
```

### 运行自检

```bash
swift run bridge-cli doctor --config ./config/config.local.json
```

### 查看可用 Reminders 列表

```bash
swift run bridge-cli list-lists --config ./config/config.local.json
```

### 查看 bridge 实际抓到的 reminders

```bash
swift run bridge-cli inspect-reminders --config ./config/config.local.json
```

### 查看 planner 生成的同步计划

```bash
swift run bridge-cli inspect-sync --config ./config/config.local.json
```

### 查看 push / accepted / ack 的完整调试快照

```bash
swift run bridge-cli debug-sync --config ./config/config.local.json
```

---

## BridgeApp 运行方式

### 单次执行

```bash
swift run BridgeApp --config ./config/config.local.json --once
```

### 按配置周期持续运行

```bash
swift run BridgeApp --config ./config/config.local.json
```

### 限制运行轮次（调试用）

```bash
swift run BridgeApp --config ./config/config.local.json --max-iterations 3
```

---

## 真机验证建议流程

### 1. 先确认配置与列表

```bash
swift run bridge-cli print-config --config ./config/config.local.json
swift run bridge-cli doctor --config ./config/config.local.json
swift run bridge-cli list-lists --config ./config/config.local.json
```

### 2. 在目标 reminder 列表里新建一个全新的提醒

例如：

- `Bridge smoke test 004`

### 3. 立即运行 `debug-sync`

```bash
swift run bridge-cli debug-sync --config ./config/config.local.json
```

### 4. 看这几个关键字段

```text
planned_push_mutations_count
push_request_tasks_count
push_response_accepted_count
report_pushed
report_acked
```

### 首次 create push 的预期

```text
push_response_accepted_count >= 1
report_pushed >= 1
report_acked >= 1
```

并且 `push_response_accepted` 中的 `reminderID` 应该正确对应到这次新建的那条 reminder。

---

## 已确认修复过的问题

这轮联调中，已经修过这些关键问题：

### 1. create mutation 在 request 组装层被丢弃

旧实现只传 `[PushTaskVersion]`，导致 `taskID=nil` 的新建任务在 push 前就被过滤掉。

**修复后：** 改为传完整 `PushTaskMutation`。

### 2. backend 旧 contract 导致 422

旧后端仍要求 `task_id/version`，create push 会报：

- missing `task_id`
- missing `version`

**修复后：** backend `/api/sync/apple/push` 已支持 `task_id == null` 的 create 场景。

### 3. backend 时间格式导致 bridge 解码失败

后端返回过不带 `Z` 的时间，bridge 端严格 `.iso8601` 解码会失败。

**修复后：**
- bridge 端已兼容无 `Z` 时间
- backend 端已统一输出 UTC Zulu 时间

### 4. accepted 被 bridge 吞掉

accepted 曾经能从 backend 返回，但在 bridge 端回填过程中被丢失，导致：

- `push_response_accepted_count=0`
- `report_pushed=0`

**修复后：** accepted 已能正确进入 bridge 统计。

### 5. accepted reminderID 错配

在 request 多条、accepted 只返回部分条目时，bridge 曾经按顺序 zip 绑定，导致 accepted 错配到 request 第一条 reminder。

**修复后：** 现在按以下优先级精确匹配：
1. `taskID`
2. `task.sourceRecordID` ↔ `externalIdentifier`
3. `task.sourceRecordID` ↔ `reminderID`

---

## 线上环境说明

### `gtd.5666.net` 的真实入口

当前线上链路确认是：

- `gtd.5666.net`
- → `43.134.109.206`
- → `nginx`
- → `127.0.0.1:18000`
- → `ios-gtd-backend` 容器内 `8000`

### 注意

同机还有一个 `finpad-api` 占用宿主机 `:8000`。

所以：

- **不要再用宿主机 `8000` 验证 ios-gtd backend**
- ios-gtd backend 应统一用：
  - 外网：`https://gtd.5666.net`
  - 宿主机：`http://127.0.0.1:18000`

---

## 推荐验证命令

### 健康检查

```bash
curl -i https://gtd.5666.net/api/health
```

### 单次 debug 验证

```bash
swift run bridge-cli debug-sync --config ./config/config.local.json
```

### 单次正式执行

```bash
swift run BridgeApp --config ./config/config.local.json --once
```

### 完整测试

```bash
swift test
```

或只跑 HTTP contract tests：

```bash
swift test --filter URLSessionBackendSyncClientContractTests
```

---

## 关键提交

### 已推送的关键修复

- `6fdcc5b` `debug(mac-sync-bridge): trace push request and response path`
- `607a1ca` `fix(sync): carry create mutations through apple push contract`
- `b97f46c` `test(mac-sync-bridge): fix create push acceptance stub`
- `89a5626` `fix(mac-sync-bridge): tolerate ISO8601 dates without Z suffix`
- `8a1c2de` `Fix bridge push accepted mapping for create sync`
- `81ba470` `fix(sync): normalize bridge datetimes to utc zulu`
- `d8a3365` `fix(mac-sync-bridge): match accepted pushes by source ref`
- `17b6a78` `chore(backend): add sqlite sync schema repair script`

---

## 当前阶段结论

这套 `mac-sync-bridge` 已经从“代码 scaffold / 本地假跑”推进到：

# 用户 Mac + 真实 Apple Reminders + 真实 backend 的首轮 create push 联调已打通

接下来如果继续做，优先级会从“打通主链路”切换到：

- 幂等表现优化
- 已 ack reminder 的 planner 收敛优化
- 运行方式（LaunchAgent / daemon）固化
- 文档和测试完善
