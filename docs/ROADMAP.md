# ROADMAP

本文把 `PRD` 与 `TECH_SPEC` 收敛成可执行的阶段计划，目标是优先跑通：

- 线上任务主库
- Apple Reminders 双向同步闭环
- AI 对话可稳定调用的 GTD 能力

原则：不扩路线，只把现有方案拆细、排优先级、暴露风险。

---

## 1. 目标拆解

## 1.1 MVP 目标

MVP 不是“功能全”，而是跑通一个真正可用的闭环：

1. 用户可通过 API / 对话创建和整理任务
2. 用户继续用 Apple Reminders 做日常操作
3. 线上主库与 Apple Reminders 能双向同步核心字段
4. AI 能基于主库做查询、整理、批量更新

## 1.2 MVP 范围内核心字段

MVP 同步与管理的最小字段集：

- title
- note
- status / completed
- bucket
- due_at
- remind_at
- project_id（仅主库内）
- tags（仅主库内）

说明：

- Apple Reminders 天然不承载完整 GTD 语义，`project/tag/bucket` 需通过映射策略处理。
- MVP 不追求 Apple 侧完整还原全部 GTD 结构，优先保证核心操作不丢数据。

---

## 2. 里程碑总览

## M0：后端骨架可运行（已基本完成）

目标：把主库、基础模型、最小 CRUD 跑起来。

已完成：

- FastAPI 项目结构
- SQLAlchemy 模型
- Alembic 初始迁移
- SQLite 本地开发兼容
- Health / Projects / Tags / Tasks 基础接口
- `POST /tasks/{id}/complete`
- 初始 README / PRD / TECH_SPEC

验收标准：

- 本地可启动服务
- 可创建/查询/修改/删除任务
- Swagger 可浏览接口

---

## M1：任务域可用于 GTD 整理（P0）

目标：让主库先具备“可被 AI 真正拿来整理”的能力。

### 关键任务

1. 任务接口补齐
   - `POST /tasks/{id}/reopen`
   - `POST /tasks/batch-update`
   - 统一完成/重开/删除的状态迁移规则

2. 查询语义补齐
   - `GET /tasks` 完善 done/deleted 筛选
   - 增加 `tag_id` / `sort_by` / `sort_order`
   - 增加 Today / Waiting / Inbox 视图接口或等价查询封装

3. 领域一致性
   - 引入 `version` 乐观锁校验
   - 统一 `last_modified_by`
   - 对 `project_id`、`tag_ids` 做存在性校验

4. 可追踪性
   - 自动写入 `operation_logs`
   - 明确操作来源：`chat` / `api` / `apple_sync` / `system`

### 验收标准

- AI 可以稳定完成：记录、列出、批量归类、完成、重开
- 批量整理不会出现半更新半失败的混乱状态
- 能追踪最近一次是谁改了任务

### 主要风险

- 当前 `version` 字段未真正参与并发控制，后面接同步会放大冲突问题
- 物理删除会破坏同步映射与审计链路

---

## M2：Apple Reminders 同步桥 MVP（P0）

目标：把“Apple 原生入口”真正接入主库。

### 关键任务

1. 同步运行管理
   - `POST /sync/runs/start`
   - `POST /sync/runs/{id}/finish`
   - `GET /sync/runs`

2. Pull 链路（Apple -> Backend）
   - `POST /sync/apple/pull`
   - 建立 `apple_reminder_mappings`
   - 支持新增、更新、删除变更

3. Push 链路（Backend -> Apple）
   - `POST /sync/apple/push`
   - `POST /sync/apple/ack`
   - 回写成功后更新 `last_synced_task_version`

4. 初次同步策略
   - 支持全量初始化导入
   - 明确“首次绑定同名任务是否合并”的规则

5. 冲突处理 MVP
   - 检测服务端与 Apple 侧并发修改
   - 冲突先记录，不自动乱合并
   - 提供 `GET /sync/conflicts` 查看冲突

### 验收标准

- 手机或 Mac Reminders 中新建/修改/完成任务后，主库能看到变化
- 主库中通过 API/对话修改任务后，Apple Reminders 能回写成功
- 至少能追踪每次同步 run 的状态、统计与失败原因

### 主要风险

- EventKit 权限、后台运行、系统休眠会影响桥稳定性
- Apple Reminder 模型与 GTD 模型不完全对齐，映射策略需要克制
- 初次全量同步时，重复任务识别容易出错

---

## M3：AI 助手接口层（P1）

目标：减少 prompt 侧即兴拼装逻辑，让 AI 对话用稳定后端语义工作。

### 关键任务

1. Capture 能力
   - `POST /assistant/capture`
   - 支持自然语言快速入 Inbox
   - 支持 `dry_run`

2. 整理能力
   - `POST /assistant/inbox-organize`
   - 批量建议 bucket / project / tags
   - 支持 suggestion 与 apply 两种模式

3. 查询视图
   - `GET /assistant/views/today`
   - `GET /assistant/views/waiting`
   - `GET /assistant/views/project-summary`

4. 执行动作层
   - `POST /assistant/execute`
   - 把高层动作映射到底层 task/project/tag API

### 验收标准

- 对话层不需要了解太多底层数据细节，也能稳定完成 GTD 操作
- “记一下”“列出今天任务”“整理 inbox” 这些高频动作有固定 API 承接

### 主要风险

- 如果 assistant 接口过早做太厚，会和通用 CRUD 重叠严重
- 自然语言解析与真实执行混在一起，容易让排障困难

---

## M4：可靠性与上线准备（P1）

目标：把 MVP 从“能跑”推进到“可持续跑”。

### 关键任务

1. 鉴权
   - AI / 管理端 token
   - Sync Bridge 独立 token 与 bridge_id 绑定

2. 日志与可观测性
   - 结构化日志
   - 请求 ID / sync run ID 串联
   - 同步错误明细落表

3. 数据安全
   - 删除改为软删除
   - 基础备份策略
   - 迁移回滚演练

4. 测试
   - CRUD 测试
   - 筛选/排序测试
   - 完成/重开/批量更新测试
   - sync pull/push/ack 测试

5. 部署
   - Dockerfile / compose
   - PostgreSQL 生产配置
   - 反向代理与 HTTPS

### 验收标准

- 服务重启、桥重启、重复 ack 等场景不会轻易把数据搞乱
- 出问题时能查到 run、任务、mapping、错误明细

### 主要风险

- 没有鉴权就暴露写接口，上线风险很高
- 没有幂等设计，同步重试会导致重复写入或错误覆盖

---

## 3. 优先级矩阵

## P0：必须先做

这些直接决定 MVP 是否成立：

- 任务域补齐：`reopen`、`batch-update`、视图查询
- `operation_logs` 接线
- Apple sync run / pull / push / ack 主链路
- 冲突记录与最小可见性
- 软删除策略设计定稿

## P1：建议紧随其后

这些决定产品是否好用、是否能稳定迭代：

- assistant 高层接口
- 鉴权
- 结构化日志
- Postgres 生产化配置
- 更完整测试

## P2：可以后置

- 更丰富的统计报表
- 多端 UI
- 更复杂的 GTD 自动化规则
- 多人协作
- CalDAV 服务端兼容

---

## 4. 分阶段任务清单

## 阶段 A：把任务域做扎实

建议顺序：

1. 明确 `Task` 状态迁移规则
2. 增加 `reopen`
3. 增加 `batch-update`
4. 引入软删除
5. 接 `operation_logs`
6. 为 sync 预留 outbox / 待回写机制（可先用简化表或查询规则）

产出物：

- 可直接支持 AI 整理的任务 API
- 更稳定的数据一致性

## 阶段 B：接通 Apple Sync MVP

建议顺序：

1. 定义 bridge 与 sync run 生命周期
2. 实现 Apple pull
3. 实现 server push 出队
4. 实现 ack 回写
5. 加入冲突检测
6. 做初次全量同步脚本/模式

产出物：

- 真正的双向同步闭环

## 阶段 C：加 AI 友好的高层接口

建议顺序：

1. `capture`
2. `today` / `waiting` 视图
3. `inbox-organize`
4. `execute`

产出物：

- 对话层可稳定调用，不必每次手工编排 CRUD

## 阶段 D：上线前加固

建议顺序：

1. auth
2. logging
3. tests
4. deploy docs
5. backup / recovery

---

## 5. 关键设计决策提醒

## 5.1 主库优先不能动摇

虽然 Apple Reminders 是主入口之一，但真相源仍应是后端主库。否则：

- AI 整理能力会受限
- project/tag/bucket 等 GTD 语义无法稳定保留
- 日后扩 Web/统计/自动化会很痛苦

## 5.2 不要过早追求 Apple 侧完全映射 GTD

Apple Reminders 更适合做自然入口，不适合承载全部任务语义。MVP 要克制：

- 先同步核心任务字段
- GTD 结构留在主库侧表达
- 必要时只做有限列表映射，而不是强行等价映射全部 bucket/project/tag

## 5.3 assistant 层应该薄一些

assistant 接口的职责是：

- 承接高频意图
- 固化常用查询与整理动作
- 降低 prompt 复杂度

不是再造一套和 CRUD 平行的业务系统。

---

## 6. 主要风险清单

## 6.1 数据一致性风险

风险：

- API 修改与 Apple 修改同时发生
- 删除/完成/重开在不同端语义不一致

应对：

- 落地 `version`
- mapping 记录 `last_synced_task_version`
- 冲突先记录，别静默覆盖

## 6.2 同步幂等风险

风险：

- 桥重试导致重复导入或重复回写
- ack 丢失造成重复 push

应对：

- 以 `task_id + version` 作为 push 幂等单元
- pull 侧以 `apple_reminder_id + apple_modified_at` 去重
- run 级别保留统计与明细

## 6.3 删除策略风险

风险：

- 物理删除后无法审计，也无法安全同步到 Apple 侧

应对：

- 尽快改为软删除
- 默认查询不返回 deleted
- 真正清理作为单独维护动作

## 6.4 桥接环境风险

风险：

- macOS 权限、EventKit 授权、系统睡眠、LaunchAgent 异常

应对：

- 设计桥心跳与 sync run 监控
- 错误码标准化
- 支持手动重试同步

## 6.5 认证与暴露面风险

风险：

- 当前 API 无 auth，不适合直接暴露公网

应对：

- 在进入真实使用前补上 token auth
- 先放内网、受控机器、反向代理白名单后面

---

## 7. 建议开发顺序（最短闭环）

如果现在继续推进，我建议按这个顺序干：

1. 补 `reopen` + `batch-update`
2. 接 `operation_logs`
3. 把删除从物理删改成软删除
4. 做 sync run 生命周期接口
5. 做 `apple pull`
6. 做 `apple push + ack`
7. 再补 `assistant/capture` 与查询视图
8. 最后做 auth / logging / deploy

这个顺序的好处是：

- 先把核心任务域打稳
- 再接高风险的同步
- 最后再做体验层封装

---

## 8. 当前文档产出对应关系

本次文档补齐后，建议这样使用：

- `docs/PRD.md`：看产品目标与边界
- `docs/TECH_SPEC.md`：看架构与数据模型
- `docs/API_SPEC.md`：按接口实现开发
- `docs/ROADMAP.md`：按阶段排期和拆任务

这样基本就能支撑后续继续编码，不用再从零补设计口径。