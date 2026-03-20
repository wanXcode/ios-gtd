# Feishu 强执行 Capture MVP

目标：让当前 OpenClaw Feishu 会话里，以 `提醒：` / `任务：` / `待办：` 开头的消息，能够真正写入 `ios-gtd` backend，而不是只停留在聊天理解层。

## 这次补的最小可用件

### 1) backend parser 直通前缀

已在 `backend/app/services/assistant.py` 增加以下前缀的强制任务意图识别与前缀剥离：

- `提醒：` / `提醒:`
- `任务：` / `任务:`
- `待办：` / `待办:`

所以现在 backend 本身就能正确解析：

- `提醒：明晚8点给张三发合同`
- `任务：补发发票`
- `待办：整理报销单`

### 2) 本机桥接脚本

新增：`scripts/feishu_capture_to_backend.py`

作用：把一条 Feishu 文本消息直接 POST 到 backend：

- endpoint: `POST /api/assistant/capture`
- 默认 `apply=true`（真正落库）
- 可带 `source_ref=Feishu message_id`
- stdout 输出精简 JSON，便于主 agent 判断是否创建成功、是否需要追问

## 主 agent 的最小调用方式

当主会话收到消息文本满足以下任一前缀时：

- `提醒：`
- `提醒:`
- `任务：`
- `任务:`
- `待办：`
- `待办:`

直接执行：

```bash
python3 /root/.openclaw/workspace/ios-gtd/scripts/feishu_capture_to_backend.py \
  '提醒：明晚8点给张三发合同' \
  --source feishu_chat \
  --source-ref om_xxx \
  --actor openclaw_feishu
```

如果主 agent 已知这条消息来自当前 Feishu 私聊，可把 `--source-ref` 设成当前 message_id，便于后续追踪。

## 返回约定

脚本输出形如：

```json
{
  "applied": true,
  "created": true,
  "entity_type": "task",
  "task_id": "...",
  "project_id": null,
  "summary": "给张三发合同",
  "bucket": "next",
  "needs_confirmation": false,
  "questions": [],
  "error_code": null,
  "raw": {"...": "..."},
  "http_status": 200
}
```

退出码：

- `0`：成功，且不需要补充确认
- `1`：HTTP / 网络失败
- `2`：请求成功，但 backend 判断 `needs_confirmation=true`，主 agent 应继续追问用户

## 环境变量（可选）

脚本支持：

- `IOS_GTD_BACKEND`：默认 `http://127.0.0.1:8000`
- `IOS_GTD_TIMEZONE`：默认 `Asia/Shanghai`
- `IOS_GTD_SOURCE`：默认 `feishu_chat`
- `IOS_GTD_ACTOR`：默认 `openclaw_feishu`

## 现实边界 / 当前缺口

### 已做到

- backend 已明确支持三类前缀
- 主 agent 已有一个稳定、无人工参与的本机桥接入口
- 只要主 agent 在收到这类消息时调用脚本，就会真正落库到 backend

### 还没做到的“完全自动”部分

当前没有发现 OpenClaw/Feishu 插件层一个现成的、无需改插件源码即可“自动拦截所有入站消息并执行本机脚本”的官方配置位。

因此这版 MVP 的自动化边界是：

- **主 agent 逻辑自动判断前缀并调用脚本**：可实现、且已经具备最小执行件
- **绕过主 agent，在插件层无条件自动落库**：目前未发现现成可配置入口；若一定要做，需要进一步改 OpenClaw / Feishu 插件源码或新增入站 hook 能力

## 推荐主会话采用的响应逻辑

1. 检测文本是否以上述前缀开头
2. 调 `feishu_capture_to_backend.py`
3. 如果 `created=true && needs_confirmation=false`：回复用户“已记下/已创建”，并可附 task_id 或摘要
4. 如果 `needs_confirmation=true`：把 `questions[0]` 直接追问给用户
5. 如果失败：回复“后端写入失败”，并附简短错误

## 本地手工 smoke

```bash
python3 /root/.openclaw/workspace/ios-gtd/scripts/feishu_capture_to_backend.py '提醒：明晚8点给张三发合同'
python3 /root/.openclaw/workspace/ios-gtd/scripts/feishu_capture_to_backend.py '任务：补发发票'
python3 /root/.openclaw/workspace/ios-gtd/scripts/feishu_capture_to_backend.py '待办：晚点看下邮箱'
```

最后一个例子会返回 `needs_confirmation=true`，符合当前 backend 的保守策略。
