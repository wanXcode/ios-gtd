# 对话 -> backend -> Mac Reminders 最小闭环 smoke

目标不是做正式产品入口，而是先把这条主线手工跑通：

1. 用户说一句自然语言
2. backend assistant capture 解析并创建 task
3. Mac 上运行 `BridgeApp --once`
4. Apple Reminders 出现/更新对应提醒事项

---

## 当前结论

截至当前仓库状态：

- backend assistant capture 已可用
- 当 `needs_confirmation=true` 时，`apply=true` 不会误写库
- `mac-sync-bridge` 已有真实 EventKit 写回能力
- **仍缺的是一条方便联调的 smoke 路径**

所以这里补了一个最小脚本：

- `scripts/chat_to_reminders_smoke.py`

它做的事很简单：

- 调 `POST /api/assistant/capture`
- 可选择 `apply=true` 真创建任务
- 创建成功后，打印下一步应该在 Mac 上执行的 bridge 命令

---

## 1. 先确保 backend 在运行

例如本地：

```bash
cd backend
.venv/bin/uvicorn app.main:app --reload
```

默认脚本会访问：

- `http://127.0.0.1:8000`

也可以用 `--backend` 覆盖。

---

## 2. parse-only 试一条

```bash
cd /root/.openclaw/workspace/ios-gtd
python3 scripts/chat_to_reminders_smoke.py "明晚8点提醒我给张三发合同"
```

这一步只看解析结果，不落库。

---

## 3. 真创建一条 task

```bash
cd /root/.openclaw/workspace/ios-gtd
python3 scripts/chat_to_reminders_smoke.py "明晚8点提醒我给张三发合同" --apply --print-bridge-command
```

预期：

- stdout 打印 assistant capture 返回 JSON
- 若 `needs_confirmation=false`，则 `created` 不为空
- 最后会打印一条建议命令，例如：

```bash
cd mac-sync-bridge && swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

---

## 4. 在 Mac 上执行 bridge 单轮同步

在用户自己的 Mac 上执行：

```bash
cd mac-sync-bridge
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

然后去 Apple Reminders 目标列表里检查：

- 是否出现新提醒
- 标题是否正确
- due 是否正确
- 是否没有重复创建

---

## 5. 如果想一步跑（仅限脚本就在 Mac 本机时）

```bash
python3 scripts/chat_to_reminders_smoke.py "明晚8点提醒我给张三发合同" --apply --run-bridge-once
```

注意：

- 这要求脚本运行环境本身就是那台可访问 EventKit 的 Mac
- 在 Linux / 远程服务器 / OpenClaw 主机上，这个选项没有意义

---

## 6. 当前 smoke 的定位

这不是正式“对话产品入口”，只是一个联调辅助器。

它的价值在于：

- 把“自然语言创建 task”固定成可重复命令
- 把“下一步怎么触发 Mac 本地提醒事项写回”说清楚
- 先验证主链路，不在这一步引入额外聊天平台接线复杂度

等这条手工主链路稳定后，再考虑把真正的聊天入口壳接上。
