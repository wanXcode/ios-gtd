# 新 Mac 部署说明书（ios-gtd 本地提醒事项桥）

这份说明书只回答一个问题：

**一台全新的 Mac，要装什么、配什么，才能让这台 Mac 的 Apple Reminders 接入 ios-gtd，并支持后续“对话 -> backend -> 本地提醒事项”的闭环。**

不讲历史，不拆概念，直接按落地顺序来。

---

## 一、这台新 Mac 上最终要跑什么

核心只有一个本地组件：

- `mac-sync-bridge`

它负责：

1. 读取这台 Mac 上的 Apple Reminders
2. 把本地提醒事项变化同步到 GTD backend
3. 把 backend 里的任务变化回写到这台 Mac 的 Reminders

所以，新 Mac 真正要部署的，不是整套服务，而是：

- 本地代码仓库（至少包含 `mac-sync-bridge/`）
- Swift/Xcode 环境
- 一个 bridge 配置文件
- Reminders 权限
- 可选：LaunchAgent 常驻

---

## 二、前置条件

这台 Mac 需要满足：

- macOS 14+
- Xcode 15+（或至少可用的 Swift 5.10 toolchain）
- 已登录 Apple 账号，并能正常打开 Reminders
- 能访问 backend：`https://gtd.5666.net`

先在终端确认：

```bash
xcodebuild -version
swift --version
```

如果这两个命令跑不通，先装 Xcode / Command Line Tools。

---

## 三、在新 Mac 上要准备哪些东西

### 1）代码仓库

把 `ios-gtd` 仓库拉到本地，例如：

```bash
git clone <你的仓库地址>
cd ios-gtd
```

后面所有命令默认都在这个仓库里执行。

### 2）本地配置文件

要准备这份文件：

```text
~/Library/Application Support/GTD/mac-sync-bridge/config.json
```

先复制样板：

```bash
cd mac-sync-bridge
mkdir -p ~/Library/Application\ Support/GTD/mac-sync-bridge
cp config/config.example.json ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

### 3）Apple Reminders 目标列表

你至少需要先在 Reminders 里准备好要同步的列表。

建议一开始先只配 **一个测试列表**，例如：

- `GTD Sync Test`

这样最容易确认链路是否通了，避免一上来全量列表混在一起。

### 4）bridge token / backend 地址

当前 backend 用：

- `https://gtd.5666.net`

配置文件里还需要一个：

- `apiToken`

这个 token 是 bridge 调 backend sync 接口时用的。

如果你这边还没有最终固定 token，就先留占位，后面我再帮你补。

---

## 四、config.json 应该怎么填

新 Mac 上至少要改这几个字段：

```json
{
  "bridgeID": "你的这台新Mac名字",
  "backendBaseURL": "https://gtd.5666.net",
  "apiToken": "你的bridge token",
  "sqlitePath": "~/Library/Application Support/GTD/mac-sync-bridge/bridge-state.sqlite",
  "syncIntervalSeconds": 60,
  "defaultReminderListIdentifier": "你的默认列表ID",
  "syncedReminderListIdentifiers": [
    "你的列表ID"
  ],
  "includeCompletedReminders": true,
  "backendTimeoutSeconds": 30
}
```

### 字段解释

#### `bridgeID`
给这台 Mac 一个稳定身份，不要每次改。

建议：

- `wan-macbook-air`
- `wan-mac-mini`
- `wan-mbp-2026`

#### `backendBaseURL`
直接填：

- `https://gtd.5666.net`

#### `apiToken`
bridge 调 backend 用的 token。

#### `sqlitePath`
保持默认即可：

- `~/Library/Application Support/GTD/mac-sync-bridge/bridge-state.sqlite`

这是这台 Mac 的本地同步状态库。

#### `defaultReminderListIdentifier`
默认写回的 Reminders 列表 ID。

#### `syncedReminderListIdentifiers`
这台 bridge 要监听/同步的列表 ID 数组。

**新机器第一次部署时，强烈建议这里只放一个测试列表 ID。**

#### `syncIntervalSeconds`
建议先用：

- `60`

调试阶段够用了。

---

## 五、怎么拿到 Reminders 列表 ID

在仓库里执行：

```bash
cd mac-sync-bridge
swift run bridge-cli list-lists --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

如果第一次跑会触发权限请求，允许它访问 Reminders。

命令输出里会看到类似：

```text
<LIST_ID>    GTD Sync Test    writable=true    source=...
```

把你要同步的列表 ID 填进：

- `defaultReminderListIdentifier`
- `syncedReminderListIdentifiers`

---

## 六、首次部署顺序（照着跑就行）

### 第 1 步：编译检查

```bash
cd ios-gtd/mac-sync-bridge
swift build
swift test
```

目标：确保新 Mac 的 Swift 环境没问题。

### 第 2 步：确认配置和权限

```bash
swift run bridge-cli print-config --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
swift run bridge-cli doctor --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

你要重点看这几个字段：

- `bridge_id=...`
- `authorization=authorized`
- `backend=https://gtd.5666.net`
- `sqlite=...`
- `default_list=...`
- `discovered_lists=...`

如果 `authorization` 不是 `authorized`，去系统设置里给 Reminders 权限。

### 第 3 步：列出提醒事项列表并填对 list ID

```bash
swift run bridge-cli list-lists --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json
```

确认 config 里的 list ID 是对的。

### 第 4 步：跑一次单轮同步

```bash
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

这一步的目标不是一次性验收全部逻辑，而是先确认：

- 程序能启动
- 配置能读取
- 能访问 Reminders
- 能访问 backend
- 本地 sqlite 会落盘

---

## 七、怎么验证这台新 Mac 已经接好了

建议做两个 smoke：

### 场景 A：Apple -> backend

1. 在这台新 Mac 的目标 Reminders 列表中新建一条提醒，例如：
   - `New Mac Pull Smoke`
2. 执行：

```bash
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

3. 看 bridge 输出里这些字段：

- `planned_push_mutations_count`
- `push_request_tasks_count`
- `push_response_accepted_count`
- `report_pushed`
- `report_acked`

至少应该看到：

- `push_response_accepted_count >= 1`
- `report_pushed >= 1`
- `report_acked >= 1`

### 场景 B：backend -> Apple

1. 在 backend 新建或修改一条 task
2. 在这台新 Mac 上执行：

```bash
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

3. 回到 Reminders 看：

- 有没有出现新提醒
- 标题对不对
- due 对不对
- 是否重复创建

这一步就是后续“你跟我对话，我来改你本地提醒事项”的基础。

---

## 八、要不要装常驻服务

如果只是首次联调，可以先不装。

如果你准备让这台新 Mac 正式作为同步机器长期运行，就装 LaunchAgent。

安装命令：

```bash
cd ios-gtd/mac-sync-bridge
./scripts/install_launch_agent.sh
```

它会自动做这些事：

- 创建 `~/Library/LaunchAgents/`
- 创建配置目录
- 渲染 `com.iosgtd.syncbridge.plist`
- 注册并启动 LaunchAgent

安装后常用检查命令：

```bash
launchctl print gui/$(id -u)/com.iosgtd.syncbridge
```

看日志：

```bash
tail -f ~/Library/Logs/GTD/mac-sync-bridge/bridge.stdout.log
tail -f ~/Library/Logs/GTD/mac-sync-bridge/bridge.stderr.log
```

---

## 九、新 Mac 上最终应该有哪些本地文件

至少这些：

### 代码目录

```text
<你的工作目录>/ios-gtd/
```

### 配置文件

```text
~/Library/Application Support/GTD/mac-sync-bridge/config.json
```

### 本地状态库

```text
~/Library/Application Support/GTD/mac-sync-bridge/bridge-state.sqlite
```

### LaunchAgent（如果装了）

```text
~/Library/LaunchAgents/com.iosgtd.syncbridge.plist
```

### 日志目录（如果装了）

```text
~/Library/Logs/GTD/mac-sync-bridge/
```

---

## 十、最容易出问题的地方

### 1）Reminders 权限没给
表现：

- `doctor` 跑不通
- `authorization != authorized`

处理：

- 系统设置 -> 隐私与安全性 -> 提醒事项(Reminders)
- 给终端 / Xcode / 相关进程权限

### 2）list ID 配错
表现：

- 程序能跑，但抓不到你想同步的列表
- backend / Apple 一边正常，一边没变化

处理：

- 用 `bridge-cli list-lists` 重新确认
- 只保留一个测试列表先跑通

### 3）backend 地址配错
表现：

- doctor 通过，但 sync 时报网络错误

处理：

- 确认 `backendBaseURL` 是：`https://gtd.5666.net`

### 4）token 不对
表现：

- 能访问网络，但 push/pull/ack 返回鉴权失败

处理：

- 更换正确的 bridge token

### 5）新 Mac 没有完整 Swift/Xcode 环境
表现：

- `swift build` / `swift run` 直接失败

处理：

- 先装 Xcode 和 command line tools

---

## 十一、给你的最简执行版

如果你只想看最短步骤，就按这个：

```bash
# 1. 拉代码
cd <你的工作目录>
git clone <你的仓库地址>
cd ios-gtd

# 2. 准备 config
cd mac-sync-bridge
mkdir -p ~/Library/Application\ Support/GTD/mac-sync-bridge
cp config/config.example.json ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json

# 3. 编译
swift build
swift test

# 4. 看 Reminders 列表
swift run bridge-cli list-lists --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json

# 5. 编辑 config.json，填 bridgeID/backend/token/list IDs

# 6. 自检
swift run bridge-cli doctor --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json

# 7. 单轮同步
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once

# 8. 需要常驻再装 LaunchAgent
./scripts/install_launch_agent.sh
```

---

## 十二、这台新 Mac 部署完成后的意义

当这台 Mac 的 bridge 跑稳后，后面要做的就不是“怎么接 Apple Reminders”了，
而是更上层的产品闭环：

- 你在我这里说一句话
- 我创建/修改 backend task
- 这台 Mac 自动把变更写回本地 Reminders

所以新 Mac 这份部署说明，本质上是在铺那条最后要用的主链路。
