# BridgeCoreTests

建议先写：
- Apple 新任务 -> backend 创建 mapping
- backend 更新 -> Apple 写回
- 同字段冲突 -> LWW
- 网络失败 -> retry pending
