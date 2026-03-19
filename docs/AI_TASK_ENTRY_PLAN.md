# AI 自然语言任务入口：需求与技术方案

## 1. 背景

当前 `ios-gtd` 已完成一条关键同步闭环：

- Apple Reminders → mac-sync-bridge → GTD Backend

也就是说，用户已经可以通过 Apple Reminders 作为输入入口，把任务同步到 GTD 主库。

但这还不是最终理想体验。

用户真正想要的是：

> 直接和 AI 对话，AI 帮忙理解一句自然语言里隐含的任务意图、时间、优先级、任务类型、GTD 归类，再自动写入 GTD 系统，并最终同步进 Apple Reminders。

因此，下一阶段的目标不是继续增强“纯同步”，而是补上：

- **自然语言任务入口层（AI Task Entry Layer）**

---

## 2. 当前版本判断

基于当前仓库状态与 backend 版本信息：

- `backend/pyproject.toml` → `version = "0.1.0"`

当前阶段可视为：

# ios-gtd v0.1.0

### v0.1.0 已具备能力
- backend 基础任务模型与 CRUD
- Apple sync bridge 基础架构
- Apple → backend 首轮 create push 真机闭环已打通
- `mac-sync-bridge` 支持 debug / doctor / inspect / BridgeApp runtime
- bridge 与 backend 的基础 sync contract 已可运行

### v0.1.0 仍然缺失的关键能力
- 用户通过自然语言直接创建 GTD 任务
- AI 自动将一句话解析为结构化任务字段
- backend → Apple 的对话式任务创建产品化入口
- 面向用户的自然语言任务管理 API

因此建议从 `v0.1.0` 继续往上迭代：

- `v0.2.0`：AI 自然语言任务入口 MVP
- `v0.3.0`：AI → backend → Apple 完整反向闭环
- `v0.4.0`：AI 任务整理/规划/批量管理增强

---

## 3. 产品目标

## 3.1 核心目标

让用户可以直接通过自然语言创建和管理任务，例如：

- 明晚 8 点提醒我给张三发合同
- 下周找时间整理一下报销
- 帮我建一个任务：测试一，明天晚上 8 点前执行
- 这个事情不急，先记着
- 这其实是个项目，不是单个任务

系统应当能够：

1. 识别这是不是任务
2. 判断是任务 / 项目 / 收集箱 / 等待中 / 备忘 / 日程
3. 解析时间、优先级、提醒、列表等字段
4. 在置信度足够高时直接写入 GTD
5. 在信息不足时追问用户确认
6. 后续可同步到 Apple Reminders

---

## 4. 用户故事

### 用户故事 1：一句话创建任务
作为用户，
我希望直接说“帮我建任务：测试一，明晚 8 点执行”，
系统自动帮我提取标题、时间和任务类型，
然后写入 GTD。

### 用户故事 2：模糊任务先进入 Inbox
作为用户，
我说“之后找时间把财务系统再整理一下”，
系统如果不能明确时间和归类，
应该先记入 Inbox，而不是乱定 due。

### 用户故事 3：识别项目而不是任务
作为用户，
我说“准备 Q2 产品升级方案”，
系统应识别这更像项目，
而不是一个单点待办。

### 用户故事 4：低置信度时询问
作为用户，
当我说“下周处理一下合同”，
系统应能问我：
- 要不要设截止时间？
- 放 Inbox 还是 Next Action？

### 用户故事 5：最终同步到 Apple Reminders
作为用户，
我希望和 AI 对话后创建的任务，不只是存在 backend，
而是最终能进入 Apple Reminders，形成统一任务入口体验。

---

## 5. 范围定义

## 5.1 v0.2.0 范围（MVP）

目标：先把“自然语言 → backend 结构化任务”打通。

### 包含
- 自然语言任务解析
- create_task / capture_inbox / create_project 基础意图识别
- due/remind/priority/list 基础字段提取
- 高置信度自动创建
- 低置信度追问确认
- 对话入口调用 backend 新 API 写入任务

### 不包含
- 完整的 AI 自动排程
- 批量整理任务
- 自动拆分复杂项目
- 多轮上下文规划引擎
- backend → Apple 完整产品化同步入口

---

## 5.2 v0.3.0 范围

目标：把“AI 创建任务 → Apple Reminders 出现任务”闭环做成产品能力。

### 包含
- AI 对话创建 backend task
- backend 生成待下发同步项
- bridge pull backend 变更
- Apple Reminders 中出现该任务
- 反向写入状态与 mapping 完整闭环

---

## 6. 需求拆解

## 6.1 意图识别

系统至少要识别以下意图：

- `create_task`
- `create_project`
- `capture_inbox`
- `update_task`
- `complete_task`
- `list_tasks`

v0.2.0 首先聚焦前三种。

---

## 6.2 字段提取

### 基础字段
- `summary`
- `description`
- `due_at`
- `remind_at`
- `priority`
- `bucket`
- `project_id` / `project_name`
- `tags`

### 来源字段
- `source = chat_ai`
- `source_ref = message_id`
- `created_by = ai`

---

## 6.3 GTD 归类决策

自然语言解析后，还需要进入一层 GTD 决策：

### 例子
- “给张三发合同” → `next_action`
- “等张三回复” → `waiting_for`
- “重构财务系统同步” → `project`
- “之后研究一下 OCR” → `inbox` / `someday`

v0.2.0 可先做简单规则 + AI 归类建议。

---

## 6.4 低置信度确认机制

当以下情况出现时，不应直接写入：

- 时间模糊
- 是任务还是项目不明确
- due/remind 冲突
- bucket 不确定

返回结果应明确包含：

```json
{
  "needs_confirmation": true,
  "questions": [
    "这是普通任务还是项目？",
    "要不要设置明确截止时间？"
  ]
}
```

---

## 7. 技术方案

## 7.1 总体架构

建议新增三层：

### 1）自然语言解析层（NLU Parser）
负责：
- 意图识别
- 时间解析
- 结构化字段提取

### 2）任务决策层（Task Planning Layer）
负责：
- GTD bucket 决策
- 任务 vs 项目判断
- 低置信度追问策略

### 3）任务写入层（Task Sink）
负责：
- 调用 backend task/project API
- 写入任务主库
- 记录 source / trace 信息

---

## 7.2 建议的数据结构

### 输入（自然语言）

```json
{
  "text": "明晚8点提醒我给张三发合同",
  "timezone": "Asia/Shanghai",
  "user_id": "ou_xxx",
  "message_id": "om_xxx"
}
```

### 解析输出（草稿）

```json
{
  "intent": "create_task",
  "summary": "给张三发合同",
  "description": null,
  "due_at": "2026-03-21T20:00:00+08:00",
  "remind_at": "2026-03-21T20:00:00+08:00",
  "priority": "medium",
  "bucket": "next_action",
  "confidence": 0.94,
  "needs_confirmation": false
}
```

### 最终写入 payload

```json
{
  "summary": "给张三发合同",
  "description": "",
  "due_at": "2026-03-21T20:00:00+08:00",
  "remind_at": "2026-03-21T20:00:00+08:00",
  "bucket": "next_action",
  "priority": 2,
  "source": "chat_ai",
  "source_ref": "om_xxx"
}
```

---

## 7.3 API 设计建议

### 新增接口 1：自然语言解析（dry run）

`POST /assistant/capture`

作用：
- 把自然语言转为结构化任务草稿
- 默认不直接写库
- 支持 `apply=true` 才执行写入

#### 请求示例

```json
{
  "text": "明晚8点提醒我给张三发合同",
  "timezone": "Asia/Shanghai",
  "apply": false
}
```

#### 返回示例

```json
{
  "draft": {
    "intent": "create_task",
    "summary": "给张三发合同",
    "due_at": "2026-03-21T20:00:00+08:00",
    "remind_at": "2026-03-21T20:00:00+08:00",
    "bucket": "next_action"
  },
  "needs_confirmation": false
}
```

---

### 新增接口 2：解析并创建

`POST /assistant/capture?apply=true`

作用：
- 在高置信度场景直接创建任务

返回：
- 创建后的 task/project 结果
- trace 信息

---

## 7.4 实现方式建议

### v0.2.0
- 先在 backend 内新增 `assistant` 路由层
- NLU 可先由模型直接返回 JSON schema
- 时间解析可结合规则 + 模型兜底
- bucket 决策先走规则优先、模型辅助

### v0.3.0
- 引入 backend → Apple 的稳定同步入口
- 对 AI 创建的任务打上 `source=chat_ai`
- bridge 在 pull 时把这些任务写进 Apple Reminders

---

## 8. 版本迭代建议

## v0.1.0（当前）
### 已完成
- backend 基础模型与 API
- Apple sync bridge 基础架构
- Apple → backend 首轮 create push 真机闭环

### 版本定义
> 已验证同步底座可用，但用户还不能把“和 AI 对话”当成正式任务入口。

---

## v0.2.0（下一阶段）
### 目标
**把自然语言任务入口做出来。**

### 核心功能
- 对话 → 结构化任务草稿
- create_task / capture_inbox / create_project 基础意图识别
- 高置信度自动创建
- 低置信度追问确认
- 写入 backend 主库

### 交付标准
用户可以直接说：
- 帮我记一个任务：测试一，明晚 8 点

系统能：
- 自动提取字段
- 决定 bucket
- 创建任务到 backend

---

## v0.3.0
### 目标
**把 AI 创建任务同步到 Apple Reminders。**

### 核心功能
- chat/AI → backend → Apple 完整反向闭环
- 对话创建任务后，Apple Reminders 中自动出现对应事项

### 交付标准
用户说一句：
- 帮我建任务：测试一，明晚8点

结果：
- backend 里有这条任务
- Apple Reminders 里也出现这条提醒

---

## v0.4.0
### 目标
**从“任务录入”升级到“任务管理 AI”。**

### 核心功能
- 自动归类 Inbox
- 项目/任务拆解
- 优先级建议
- 今日任务推荐
- 批量重排与周计划支持

---

## 9. 近期实施建议

建议就按下面顺序做：

### 第一步（P0）
做 `v0.2.0`：
- 新增 `POST /assistant/capture`
- 定义统一输出 schema
- 跑通自然语言 → backend task

### 第二步（P0）
把当前 bridge 常驻能力稳定化：
- launchd
- 自启动
- 日志与错误恢复

### 第三步（P1）
做 `v0.3.0`：
- backend → Apple 反向闭环产品化
- 对话建任务直接出现在 Apple Reminders

---

## 10. 一句话结论

当前 `ios-gtd` 可以定义为：

# v0.1.0：同步底座已打通

下一阶段应明确进入：

# v0.2.0：AI 自然语言任务入口

这会让系统从：
- “能同步任务”

升级为：
- “你直接和 AI 说一句，我帮你理解、安排、结构化并写入任务系统”
