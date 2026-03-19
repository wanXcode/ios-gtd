# QA Sync Report

日期：2026-03-19 (UTC)

范围：
- 仓库文档核对：`README.md`、`backend/README.md`、`docs/API_SPEC.md`、`docs/DEPLOY_TEST_CHECKLIST.md`
- 本地 backend 回归：health、tasks 主流程、assistant 高层接口、sync pull/push/ack/state
- 线上环境核对：`https://gtd.5666.net`
- 重点：sync 合同一致性、文档与实现是否一致、明显回归风险、易混淆点

---

## 结论摘要

整体判断：**仓库当前代码的 sync 能力明显已经超过“占位接口”阶段，本地主流程基本可用；但线上 `gtd.5666.net` 仍跑着旧版本/旧合同，和仓库文档、当前代码不一致。**

另外，本轮 QA 打到了一个真实 bug：
- `POST /api/sync/apple/pull` 的冲突分支在 SQLite 环境下会因为 naive/aware datetime 比较报错。
- 我已做了一个小修复：对 mapping 相关时间统一做 `_normalize_dt()`，避免直接抛 `TypeError`。
- 但进一步测试表明：**冲突判定逻辑本身仍偏脆**，在 SQLite 下可能因为 `updated_at` 粒度/刷新时机导致应判冲突时没有判出来。

所以当前状态更准确地说是：
- **Happy path：通过**
- **冲突 path：仍有风险**
- **线上部署与文档：明显不一致**

---

## 已读文档与理解

### 1. `README.md`
仓库根 README 宣称：
- tasks / projects / tags 已可运行
- Apple sync 已有 `pull / push / ack / state`
- sync 字段与 per-bridge checkpoint 已持久化
- 已适合开始部署测试

### 2. `backend/README.md`
后端 README 进一步明确：
- assistant 高层接口已实现：
  - `POST /api/assistant/capture`
  - `GET /api/assistant/views/today`
  - `GET /api/assistant/views/waiting`
- sync 已实现：
  - `POST /api/sync/apple/pull`
  - `POST /api/sync/apple/push`
  - `POST /api/sync/apple/ack`
  - `GET /api/sync/apple/state/{bridge_id}`
- 当前不是纯占位，而是面向真实 bridge bring-up 的最小可用合同

### 3. `docs/API_SPEC.md`
API 文档大体已跟上代码方向，尤其 sync 段落已经描述为：
- pull: 接收 Apple 侧 change 并落库
- push: 返回待回写本地任务变更
- ack: 按 success/failed/conflict/stale 处理
- state: 返回 per-bridge checkpoint
- assistant: today / waiting / capture 已是“部分已实现”

但文档尾部“与当前代码的差异说明”等历史段落还有残留，容易让人以为 reopen / batch-update / sync / assistant 仍未落地。**同一文档内部有旧叙述残留，存在认知噪音。**

### 4. `docs/DEPLOY_TEST_CHECKLIST.md`
这份文档已经明显过时：
- 还写着 sync 是“契约占位实现”
- 但当前仓库代码和测试已经不是占位
- 且线上环境实际又确实还是占位/旧版

这会导致很严重的误导：
- 看仓库代码：你会以为线上也该支持完整 sync/state/assistant
- 看 checklist：你又会以为线上只有占位也算正常

建议把它改成“当前仓库能力 vs 当前线上已部署能力”双栏说明，避免混淆。

---

## 本地测试结果

测试环境：
- 路径：`backend/`
- Python venv：项目内 `.venv`
- 执行：`pytest -q`

### A. 自动化测试

结果：**7 passed（原始测试集）**

已覆盖：
- health
- task lifecycle（create / complete / reopen / soft delete）
- batch update
- sync pull / push / ack 主流程
- delete via pull
- stale ack + push cursor 过滤
- state endpoint

### B. 本地手工 / smoke 验证

在迁移数据库到最新 schema 后，以下接口 smoke 通过：

#### health
- `GET /api/health` → 200

#### tasks 主流程
- `POST /api/projects` → 200/201
- `POST /api/tags` → 200/201
- `POST /api/tasks` → 201
- `PATCH /api/tasks/{id}` → 200
- `POST /api/tasks/{id}/complete` → 200
- `POST /api/tasks/{id}/reopen` → 200
- `DELETE /api/tasks/{id}` → 204
- `GET /api/tasks` 默认隐藏软删任务 → 符合预期
- `GET /api/tasks?include_deleted=true` 能看到软删任务 → 符合预期

#### assistant
- `POST /api/assistant/capture` → 200
- `POST /api/assistant/capture` with `dry_run=true` → 200
- `GET /api/assistant/views/today` → 200
- `GET /api/assistant/views/waiting` → 200

#### sync（happy path）
- `GET /api/sync/apple/state/{bridge_id}` → 200
- `POST /api/sync/apple/pull`（空 changes）→ 200
- `POST /api/sync/apple/push`（空 / 有 pending）→ 200
- `POST /api/sync/apple/ack`（空 / success ack）→ 200
- `ack future version` → 409，符合预期

---

## 本地发现的问题

### 1. sync conflict 分支会抛 datetime 比较异常

严重性：**高**

现象：
- 在 SQLite 下构造“先同步、再本地修改、再远端更新”的冲突场景时，`POST /api/sync/apple/pull` 会触发：
- `TypeError: can't compare offset-naive and offset-aware datetimes`

定位：
- 文件：`backend/app/api/routes/sync.py`
- 原因：`remote_modified_at` / `local_updated_at` 做了 normalize，但 `mapping.last_seen_apple_modified_at` 与 `mapping.updated_at` 没统一 normalize。

本轮已修：
- 对 `mapping.last_seen_apple_modified_at` 和 `mapping.updated_at` 增加 `_normalize_dt()` 处理，避免直接炸掉。

### 2. 冲突判定逻辑本身仍不稳

严重性：**高**

现象：
- 修掉 datetime 类型错误后，再次构造冲突场景，接口不再报错；
- 但预期的 `conflicts == 1` 没有出现，说明这条规则：
  - `remote_modified_at > last_seen_apple_modified_at`
  - `local_updated_at > mapping_updated_at`
  在 SQLite 环境下非常依赖 DB 时间精度和刷新时机。

影响：
- 代码声称采用保守冲突策略，但实际可能把冲突误判成普通 applied/update。
- 这会直接影响 sync 合同可靠性。

建议：
- 不要把“是否本地修改过”完全绑定在 `updated_at > mapping.updated_at` 上。
- 更稳妥的是结合：
  - `task.sync_pending`
  - `task.version > mapping.last_synced_task_version`
  - 必要时再辅以时间字段
- 补一条真正能稳定命中的 conflict 回归测试。

### 3. 本地数据库如果没跑迁移，会在 sync/state 直接报表不存在

严重性：**中**

现象：
- 直接使用已有 `backend/gtd.db` 做本地联调时，请求 `sync` 新接口会报：
  - `no such table: sync_bridge_states`

这不是代码 bug，而是**文档/联调体验风险**：
- README 虽然写了要 `alembic upgrade head`
- 但如果有人直接 `uvicorn` 启起来，就会在 sync 链路踩坑

建议：
- 在 README/部署清单里显式强调：**sync QA 前必须先 migrate 到 head**
- 最好在启动或 health 中暴露 schema version / migration mismatch 提示

---

## 线上环境测试结果（gtd.5666.net）

测试目标：`https://gtd.5666.net/api`

### 线上通过
- `GET /api/health` → 200
- 返回：`{"status":"ok","app":"ios-gtd-backend","env":"prod"}`

### 线上失败 / 与仓库不一致

#### 1. assistant 路由不存在
- `GET /api/assistant/views/today` → 404
- `GET /api/assistant/views/waiting` → 404

#### 2. sync state 路由不存在
- `GET /api/sync/apple/state/{bridge_id}` → 404

#### 3. sync 仍是旧占位实现
- `POST /api/sync/apple/push` → 200，但返回：
  - `"message":"sync push placeholder is ready for bridge integration"`
- `POST /api/sync/apple/pull` → 200，但返回：
  - `"message":"sync pull placeholder is ready for bridge integration"`
- `POST /api/sync/apple/ack` → 200，但返回：
  - `"message":"sync ack placeholder recorded mappings"`

结论：
- **线上 `gtd.5666.net` 不是当前仓库 HEAD 的 backend 行为。**
- 至少 assistant 和 sync state 没部署上去；sync 三接口也仍是老占位版本。

这也是本轮 QA 最重要的外部发现。

---

## 文档与实现一致性检查

### 一致的部分
- 仓库 README / backend README / API_SPEC 主体，已经大体反映当前代码：
  - reopen 已实现
  - batch-update 已实现
  - assistant today/waiting/capture 已实现
  - sync pull/push/ack/state 已实现

### 不一致 / 易混淆部分

#### 1. `docs/DEPLOY_TEST_CHECKLIST.md` 过时
仍把 sync 描述成“占位接口”，与当前代码不符。

#### 2. `docs/API_SPEC.md` 底部存在旧叙述残留
例如“与当前代码的差异说明”“最小实现优先级建议”等段落，和前文“已实现”描述已经不完全一致。

#### 3. 文档没有明确区分“仓库能力”和“线上已部署能力”
当前最大问题不是文档完全错，而是：
- 文档写的是仓库现状
- 线上跑的是旧部署
- 文档没有提醒这一点

---

## 建议

### P0（建议马上做）
1. **重新部署线上 backend 到当前仓库版本**
   - 目标：至少让 assistant today/waiting、sync state、真实 sync 合同上线上
2. **补一个稳定命中的 conflict 回归测试**
   - 防止 sync 冲突检测名义上存在、实际上经常判不到
3. **修正文档：明确线上当前版本落后于仓库**
   - 至少更新 `docs/DEPLOY_TEST_CHECKLIST.md`

### P1
4. **重构 conflict 判定逻辑**
   - 更依赖 version / last_synced_task_version / sync_pending
   - 少依赖 SQLite 上不稳定的 timestamp 比较
5. **把 migration 要求写得更醒目**
   - sync/state QA 前必须 `alembic upgrade head`
6. **增加一条线上部署后 smoke checklist**
   - health
   - assistant today/waiting
   - sync state
   - sync push/pull/ack 返回结构检查

### P2
7. **在 health 或独立诊断接口暴露 build/version/schema 信息**
   - 这样一眼就能看出线上是否部署到对应 commit

---

## 本轮修改

我做了一个小而明确的修复：
- 文件：`backend/app/api/routes/sync.py`
- 内容：sync conflict 比较时，对 mapping 的 datetime 也统一走 `_normalize_dt()`
- 目的：避免 SQLite/驱动差异导致的 naive vs aware datetime 异常

我还尝试补一条 conflict 回归测试，但当前逻辑无法稳定命中“conflict”判定，因此**未将该失败测试保留在提交中**。这本身也说明冲突逻辑还需要进一步设计/加固。

---

## 最终判定

### 仓库代码
- tasks 主流程：**通过**
- assistant 高层接口：**通过**
- sync happy path：**通过**
- sync conflict path：**存在高风险**

### 线上环境 `gtd.5666.net`
- health：**通过**
- assistant：**失败（未部署）**
- sync state：**失败（未部署）**
- sync push/pull/ack：**仅旧占位实现在线，不符合当前仓库合同**

### 综合
**这次 QA 最大结论不是“sync 全坏了”，而是“仓库代码和线上部署已经分叉”。**
如果接下来要做真实 bridge 联调，建议先把线上环境升级到当前 backend 版本，否则文档、代码、线上行为会一直对不上。
