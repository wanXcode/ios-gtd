# QA Sync Report

日期：2026-03-19 (UTC)

范围：
- 仓库文档核对：`README.md`、`backend/README.md`、`docs/API_SPEC.md`、`docs/DEPLOY_TEST_CHECKLIST.md`
- 本地 backend 回归：health、tasks 主流程、assistant 高层接口、sync pull/push/ack/state
- 线上环境核对：`https://gtd.5666.net` 与 x2 容器现状
- 重点：sync / assistant smoke、GitHub/main / 本地 / x2 一致性、明显回归风险

---

## 结论摘要

本轮继续 QA 后，结论和上一版报告已经不同：

- **GitHub/main 与本地仓库 HEAD 一致**：当前本地 `main` 在 `5db050c`，与 `origin/main` 对齐。
- **x2 线上 backend 已追上当前能力面**：`assistant/views/*`、`sync pull/push/ack/state` 都已在线，不再是“占位版未部署”。
- **本地真正暴露出的回归点不在 sync 主逻辑，而在测试体系本身**：`backend/tests` 原先复用了一个全局 in-memory SQLite + 全局 TestClient，导致测试互相污染；单测单独跑是绿的，全量跑会假红。
- **另外抓到一个小但真实的 sync 细节问题**：retryable failed 的 delivery 在下一次 push 重发时，会把上次失败的错误上下文清空，排障价值差。我已做最小修复，改为保留 `last_error_code / last_error_message`。

当前更准确的状态：
- **sync / assistant 本地主链路：通过**
- **线上 `gtd.5666.net` smoke：通过**
- **测试稳定性：已修复一处隔离问题**
- **delivery 错误上下文保留：已修复**
- **文档现状：上一版 QA 报告已过时，需要更新认知**

---

## 一致性核对

### 1. GitHub/main vs 本地

仓库状态：
- `main` = `5db050c`
- `origin/main` = `5db050c`

结论：
- 当前工作树基线与 GitHub/main 一致，没有“本地比远端多/少一截”的问题。

### 2. x2 线上现状

通过 SSH 检查 x2：
- 主机：`43.134.109.206`
- `docker ps` 可见容器：`ios-gtd-backend`
- compose 工作目录：`/opt/ios-gtd`
- backend 容器环境：
  - `APP_ENV=prod`
  - `APP_PORT=8000`
  - `DATABASE_URL=sqlite:////app/data/gtd.db`

线上容器内已可导入当前 sync 路由代码；从接口行为看，也符合当前合同，不再是此前 QA 报告中的旧占位实现。

### 3. 线上接口 smoke

目标：`https://gtd.5666.net/api`

通过：
- `GET /api/health` → 200
- `GET /api/assistant/views/today` → 200
- `GET /api/assistant/views/waiting` → 200
- `POST /api/sync/apple/pull`（空 changes）→ 200
- `POST /api/sync/apple/push`（空 tasks）→ 200
- `POST /api/sync/apple/ack`（空 acks）→ 200
- `GET /api/sync/apple/state/{bridge_id}` → 200

assistant capture 合同补充：
- `POST /api/assistant/capture` 使用 `{"text": ...}` 会得到 422
- 正确请求体是 `{"input": ..., "dry_run": true}` → 200

所以线上/仓库现在的主要“不一致”不是接口缺失，而是**旧 QA 认知和当前事实不一致**。

---

## 本地测试结果

测试环境：
- 路径：`backend/`
- Python venv：项目内 `.venv`
- 执行：`pytest -q`

### A. 自动化测试

结果：**11 passed**

覆盖：
- health
- task lifecycle（create / complete / reopen / soft delete）
- batch update
- sync pull / push / ack 主流程
- delete via pull
- stale ack + push cursor 去重
- conflict path
- ack change_id 合同
- retryable failed 重推
- state endpoint

### B. 本地 / 线上 smoke

本地重点：
- sync conflict 用例单独跑通过
- sync pull/push/ack 主流程用例单独跑通过
- 全量回归通过

线上重点：
- assistant views 在线
- sync state 在线
- pull/push/ack 在线且返回当前结构
- `assistant/capture` 需使用 `input` 字段

---

## 本轮发现的问题

### 1. 测试隔离缺失导致全量 pytest 假红

严重性：**高（对 QA 可信度而言）**

现象：
- 部分 sync 用例单独执行通过；
- 但全量 `pytest -q` 会出现 task / mapping / delivery 查询异常，像是任务“消失”或断言错位；
- 根因不是业务逻辑回归，而是 `backend/tests/test_api.py` 在模块加载时创建了全局 `TestClient + in-memory SQLite`，所有测试共用一份状态。

影响：
- QA 结果会被前序测试污染，出现假阴性；
- 很容易误判成 sync 主链路回归。

本轮已修：
- 新增 `backend/tests/conftest.py`
- 改成每个测试通过 fixture 获取独立的 `TestClient + SessionLocal`
- `test_api.py`、`test_sync_ack_change_id.py` 改为按测试注入上下文

结果：
- 全量测试恢复稳定，`11 passed`。

### 2. retryable failed delivery 在重推时会清空错误上下文

严重性：**中**

现象：
- 某条变更 ack 失败且 `retryable=true` 后，delivery 记录会带上 `last_error_code=timeout` 等错误信息；
- 下一次 push 重发同一 delivery 时，代码把这些错误字段清空；
- 这会让 `/sync/apple/state/{bridge_id}` 或后续排查少掉最近失败原因。

影响：
- 不影响主链路成功/失败语义；
- 但会降低 bridge 联调和线上排障可观测性。

本轮已修：
- `_get_or_create_delivery()` 在复用既有 delivery 重推时，不再清空：
  - `retryable`
  - `last_error_code`
  - `last_error_message`
- 仍会把 `status` 置回 `pending`，保留“正在重试”的语义，同时不丢上次失败上下文。

### 3. assistant capture 合同容易写错字段

严重性：**低**

现象：
- 直觉上容易发 `{"text": ...}`；
- 实际 schema 要求 `{"input": ...}`。

影响：
- smoke 时容易误判接口异常；
- 也提示 README / API_SPEC /示例里最好统一强化这一点。

---

## 文档与实现一致性检查

### 当前一致的部分
- 仓库代码、GitHub/main、本地 HEAD：一致
- x2 线上能力面：已基本追上当前仓库合同
- sync / assistant 主接口：线上与本地 smoke 一致

### 当前不一致 / 易误导的部分
1. **`docs/QA_SYNC_REPORT.md` 的旧结论已经过时**
   - 里面仍写线上是旧占位版；
   - 这不再符合当前事实。

2. **`docs/DEPLOY_TEST_CHECKLIST.md` 仍偏旧**
   - 依然把 sync 描述得偏“占位/待接线”；
   - 需要更新为当前合同与当前部署检查项。

3. **assistant capture 请求样例需要更明确写 `input`**
   - 否则 smoke 很容易误发成 `text`。

---

## 本轮修改

### 代码
- `backend/app/api/routes/sync.py`
  - 修复 retryable failed delivery 在重推时清空错误上下文的问题

### 测试
- `backend/tests/conftest.py`
  - 新增测试 fixture，给每个测试独立 DB / client
- `backend/tests/test_api.py`
  - 改为使用 fixture 注入测试上下文
- `backend/tests/test_sync_ack_change_id.py`
  - 改为使用 fixture 注入测试上下文
  - 调整 stale ack 断言为符合当前 change_id 语义
  - 补充 retryable failed 后 state 可观测性断言

---

## 建议

### P0
1. **更新/替换旧 QA 报告认知**
   - 不要再把线上 `gtd.5666.net` 视为旧占位版。

2. **更新 deploy / smoke 文档**
   - 明确当前线上 smoke 该检查：
     - health
     - assistant views
     - assistant capture（`input` 字段）
     - sync pull/push/ack/state

3. **保留测试隔离方案**
   - 不要再回到全局共享 in-memory DB 的模式。

### P1
4. **在 state 或诊断接口里继续加强 delivery 可观测性**
   - 当前保留 last error 已经更好；
   - 后续可以继续补 attempt timeline / 最近失败摘要。

5. **补充 README / API_SPEC 中 assistant capture 的正确示例**
   - 把 `input` 字段写醒目。

---

## 最终判定

### 仓库代码
- tasks 主流程：**通过**
- assistant 高层接口：**通过**
- sync happy path：**通过**
- sync conflict path：**通过（至少当前回归测试稳定）**
- delivery retry 可观测性：**已改进**

### 线上环境 `gtd.5666.net`
- health：**通过**
- assistant views：**通过**
- assistant capture：**通过（注意字段为 `input`）**
- sync pull/push/ack/state：**通过**

### 综合
**本轮 QA 的关键结论是：线上/仓库能力面已经基本对齐，当前更大的风险在“测试体系是否可靠”和“旧文档/旧 QA 结论是否还在误导人”。**
