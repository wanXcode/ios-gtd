# EventKitAdapter

封装 EventKit 对 Apple Reminders 的访问。

当前已具备：
- `ReminderStore` 协议
- `InMemoryReminderStore`
- `EventKitReminderStoreConfiguration`
- `ReminderListRecord`
- `ReminderDTOConverting` / `DefaultReminderDTOConverter`
- `EventKitReminderStore`（真实适配层结构）

## EventKitReminderStore 当前职责

### 1. 授权
- 读取当前 Reminders 授权状态
- `requestAccessIfNeeded()` 负责首次申请权限
- 未授权时明确抛出 `ReminderStoreError.accessDenied`

### 2. 扫描
- 枚举 reminder calendars / lists
- 根据 `syncedListIdentifiers` 过滤同步范围
- 批量抓取 reminders 并转换为 `ReminderRecord`
- 用 DTO converter 生成稳定 fingerprint

### 3. 写回
- `upsert(reminders:)`
  - 根据 `externalIdentifier` 找已有 reminder
  - 找不到则创建新的 `EKReminder`
  - 写 title / notes / dueDate / completed / calendar
- `delete(reminders:)`
  - 按 `externalIdentifier` 定位并删除
  - 批量操作使用 `commit: false` + 最后统一 `commit()`

## 模块边界

推荐继续保持下面这层分工：
- `BridgeCore` 只面向 `ReminderStore`
- `EventKitReminderStore` 负责 EventKit 权限、查找、保存、删除
- `ReminderDTOConverting` 负责 EventKit ↔ bridge DTO 转换与 fingerprint 语义

## 当前仍缺

- 真机验证 `lastModifiedDate` 在不同账号类型下是否稳定
- 全天任务 / 时区语义更精确的转换
- 删除缺失检测（当前只做显式 delete，不负责 scan-based tombstone inference）
- 更细的 list / bucket 映射器
- 针对 EventKit mock 的更完整测试

## 编译说明

非 macOS / 无 EventKit 环境下：
- 仍会暴露同名 `EventKitReminderStore`
- 但所有操作会抛 `eventKitUnavailable`

这样 Linux CI / 当前仓库环境仍能保留模块边界，不会阻塞其他 target 继续编译。
