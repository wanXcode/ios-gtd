# Persistence

封装本地状态存储。

当前已推进到两层：
- `InMemoryBridgeStateStore`：给 `BridgeCoreTests` 和 CLI fixture 用
- `SQLiteBridgeStateStore`：基于原生 `SQLite3` 的结构化落盘实现 / scaffold

## 已覆盖的持久化对象

- `BridgeConfiguration`
- `SyncCheckpoint`
- `ReminderTaskMapping`
- `PendingOperation`
- `SQLiteSchemaDefinition`

## SQLiteBridgeStateStore 当前能力

- 启动时自动创建父目录
- 自动执行 schema 建表 + `schema_migrations` 记录
- 默认启用 `WAL` + `foreign_keys`
- seed 单行 `bridge_configuration` / `sync_checkpoint`
- 支持 load/save configuration
- 支持 load/save checkpoint
- 支持 load/save mappings
- 支持 enqueue/update/remove pending operations
- 所有批量写入使用 transaction

## 现阶段定位

它已经不是纯接口占位，而是：
- 可以表达 bridge 状态真实怎么落 SQLite
- 可以让后续接 `BridgeCLI` / LaunchAgent 时直接复用
- 可以作为未来切到 GRDB 前的薄实现基线

但它还不是最终版，仍缺：
- 更细的 migration 机制（多版本升级而不只是 currentVersion 打点）
- busy / locked 重试策略
- rollback / corruption 恢复
- 更细粒度索引与墓碑清理策略
- 真机上的并发 / durability 压测
