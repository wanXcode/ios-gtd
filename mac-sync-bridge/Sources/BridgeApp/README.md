# BridgeApp

BridgeApp 现在不再只是占位入口，而是一个可常驻运行的 bridge host。

当前能力：
- 复用 `BridgeRuntimeConfigurationLoader` 读取 `config.json` / ENV / CLI 配置
- 启动后执行首轮同步
- 按 `syncIntervalSeconds` 持续循环同步
- 支持 `--once` 做单轮 smoke test
- 支持 `--max-iterations N` 做有限轮数验证

示例：

```bash
swift run BridgeApp --backend-base-url http://127.0.0.1:8000 --api-token "$BRIDGE_API_TOKEN" --once
swift run BridgeApp --backend-base-url http://127.0.0.1:8000 --sync-interval 60 --max-iterations 3
```

后续可继续演进为：
- LaunchAgent 启动入口
- 菜单栏状态壳
- OSLog / 持久日志
- 权限检测与错误提示入口
