# Bridge compile prep（开始整套跑通测试前）

这份文档只服务一个目标：
**在 macOS 真机上，把 `mac-sync-bridge` 提前收拾到可以开始整套联调/手工跑通测试的状态。**

不是泛化开发指南，也不是发布文档。

## 这一步解决什么

它主要消化“开始整套跑通测试前”的第 1 步：

1. 真机编译与运行入口收口
2. 固定配置与本地状态文件落位
3. LaunchAgent 常驻入口准备好
4. 再进入整套 E2E 手工联调

本轮文档和样板，目标就是把 1-3 步前置收口掉。

## 0. 前提

需要一台 macOS 14+ 开发机，并具备：

- Xcode 15+ 或至少带 Swift 5.10 toolchain
- 可访问本仓库
- 可以访问 GTD backend（本地或测试环境）
- 拥有可用的 Apple Reminders 权限

建议先确认：

```bash
xcodebuild -version
swift --version
```

## 1. 准备配置文件

先复制样板：

```bash
cd mac-sync-bridge
mkdir -p ~/Library/Application\ Support/GTD/mac-sync-bridge
cp config/config.example.json ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

至少要改这些字段：

- `bridgeID`：固定设备身份，不要每次变
- `backendBaseURL`：你的 backend 地址
- `apiToken`：bridge token
- `defaultReminderListIdentifier`
- `syncedReminderListIdentifiers`

建议规则：

- 一台 Mac 固定一个 `bridgeID`
- `sqlitePath` 不要临时目录，直接用默认 Application Support 路径
- 首次联调时 `syncIntervalSeconds` 可先设成 `60`

## 2. 先做最小编译回归

在 `mac-sync-bridge/` 下执行：

```bash
swift build
swift test
```

这里的意义不是证明真机同步完成，而是先确认：

- `BridgeRuntime`
- `BridgeApp`
- `BridgeCLI`
- `HTTPClient` contract tests

至少都能在你的 macOS toolchain 上过一遍。

如果这一步不过，不要直接进 E2E。

## 3. 先跑 doctor 和 print-config

```bash
swift run bridge-cli print-config --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
swift run bridge-cli doctor --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

期待看到：

- `bridge_id=...`
- `authorization=...`
- `backend=...`
- `sqlite=...`
- `default_list=...`
- `discovered_lists=...`

这里最关键的是确认三件事：

1. 配置真的被 loader 吃到了
2. EventKit 权限和列表发现可用
3. SQLite 路径已经固定

## 4. 做一次单轮 smoke sync

```bash
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

或者：

```bash
swift run bridge-cli sync-once --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

这一步只看“入口能否实际跑起来”，不强求双向语义全部正确。

至少需要确认：

- 进程能启动
- 能读到配置
- 能进入一次 sync 主循环
- 能在 stdout/stderr 打出成功或失败信息
- 会在 sqlite 路径下创建 state 文件

## 5. 准备 LaunchAgent 常驻入口

仓库里已提供：

- 样板 plist：`mac-sync-bridge/launchd/com.iosgtd.syncbridge.plist`
- 安装脚本：`mac-sync-bridge/scripts/install_launch_agent.sh`

推荐直接执行：

```bash
cd mac-sync-bridge
./scripts/install_launch_agent.sh
```

它会：

- 自动创建 `~/Library/LaunchAgents/`
- 如无配置则从 `config/config.example.json` 复制出 `config.json`
- 渲染 plist 中的工作目录 / 配置路径 / 日志目录
- `launchctl bootstrap + enable + kickstart`

常用检查命令：

```bash
launchctl print gui/$(id -u)/com.iosgtd.syncbridge
log stream --predicate 'process == "BridgeApp"' --level debug

tail -f ~/Library/Logs/GTD/mac-sync-bridge/bridge.stdout.log

tail -f ~/Library/Logs/GTD/mac-sync-bridge/bridge.stderr.log
```

如果只是先做联调，不想常驻，也可以暂时不装 LaunchAgent。
但在“整套跑通测试前最后准备”这个阶段，最好至少把它安装过一次，确认 daemon 入口不是最后一刻才第一次碰。

## 6. 通过标准（能继续进入 E2E）

当下面这些都成立时，就算 compile-prep 通过，可以进入整套手工联调：

- `swift build` 通过
- `swift test` 通过
- `bridge-cli doctor` 能发现 Reminders 列表
- `BridgeApp --once` 至少能完整跑完一轮
- sqlite 状态文件已落盘
- LaunchAgent 安装成功，且能看到进程/日志

如果还缺其中任一项，这一轮优先补它，不要急着做完整 E2E 结论。
