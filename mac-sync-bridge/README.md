# mac-sync-bridge

Mac Sync Bridge 是 GTD 系统的本地同步代理，负责在：
- Apple Reminders（通过 EventKit）
- GTD Backend（通过 HTTPS API）

之间执行双向同步。

当前目录先提供**工程骨架与模块边界**，目的是让后续实现可以直接接着写，而不是已经完成可运行版本。

## 目标

- 运行在 macOS
- 读取 / 写入 Apple Reminders
- 维护本地 mapping、checkpoint、重试队列
- 与后端执行 pull / push / ack

详细设计见：
- `../docs/SYNC_BRIDGE_SPEC.md`

## 建议模块结构

```text
mac-sync-bridge/
  Package.swift
  README.md
  Sources/
    BridgeApp/          # 宿主入口（后续可接 LaunchAgent / menu bar app）
    BridgeCLI/          # 命令行入口，便于本地调试与单次同步
    BridgeCore/         # 同步状态机、协调器、冲突处理、调度
    EventKitAdapter/    # EventKit 读写封装
    HTTPClient/         # GTD Backend API 客户端
    Persistence/        # SQLite / 配置 / checkpoint / mapping 存储
  Tests/
    BridgeCoreTests/
```

## 模块职责

### BridgeCore
核心同步流程：
- `SyncCoordinator`
- `PullPlanner`
- `PushPlanner`
- `ConflictResolver`
- `RetryScheduler`

### EventKitAdapter
负责：
- EventKit 授权
- Reminder 列表读取
- Reminder 写回
- Apple 对象标准化

### HTTPClient
负责：
- `/api/sync/apple/pull`
- `/api/sync/apple/push`
- `/api/sync/apple/ack`
- token、超时、重试、错误解析

### Persistence
负责：
- `BridgeConfig`
- `LocalCheckpoint`
- `ReminderTaskMapping`
- `PendingOperation`

### BridgeCLI
用于本地开发阶段：
- `run`
- `sync-once`
- `doctor`
- `print-config`

### BridgeApp
后续可演进为：
- LaunchAgent 宿主
- 菜单栏壳
- 状态提示 / 最近错误展示

## EventKit 与 macOS 限制

这是本项目的基础约束：

1. 只能运行在 macOS
2. 依赖用户授予 Reminders 权限
3. 依赖本机 Apple 账户 / iCloud Reminders 数据可用
4. Reminder 增量变化不能完全依赖系统推送，MVP 采用轮询 + 指纹比对
5. 删除检测与全天任务语义需要额外谨慎处理

## 开发建议

优先做最小闭环：

1. CLI 跑通配置加载
2. EventKit 只读 reminders
3. HTTP pull/push/ack 打通
4. 本地 checkpoint + mapping 落地
5. 单轮同步跑通

## 后续可直接补的内容

- `Package.swift` 中加入 SQLite 依赖（如 GRDB）
- 建立 `BridgeCore` 的协议层与模型层
- 先写 fake EventKit / fake backend 测试
- 再逐步接真实 EventKit

