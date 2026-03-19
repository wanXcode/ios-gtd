# GTD Backend 部署测试清单

## 当前线上环境

- 环境：x2 (`43.134.109.206`)
- 域名：`https://gtd.5666.net`
- Swagger：`https://gtd.5666.net/docs`
- 健康检查：`https://gtd.5666.net/api/health`
- 部署方式：Docker + Nginx + Let's Encrypt

## 一、基础可用性检查

### 1. 健康检查
- 打开 `https://gtd.5666.net/api/health`
- 预期：返回 JSON，字段至少包含：
  - `status: ok`
  - `app: ios-gtd-backend`

### 2. Swagger 页面
- 打开 `https://gtd.5666.net/docs`
- 预期：Swagger UI 正常加载

## 二、任务主流程测试

建议按以下顺序测试。首轮 E2E smoke 也建议严格沿用这条顺序：先把 CRUD / 生命周期跑通，再进 assistant capture，最后再进 sync pull/push/ack/state。这样一旦失败，最容易定位是在任务主模型、assistant 入口，还是 sync 桥合同。

### 1. 创建项目
接口：`POST /api/projects`
示例：
```json
{
  "name": "招聘项目"
}
```
预期：返回项目对象，包含 `id`

### 2. 创建标签
接口：`POST /api/tags`
示例：
```json
{
  "name": "重要"
}
```
预期：返回标签对象，包含 `id`

### 3. 创建任务
接口：`POST /api/tasks`
示例：
```json
{
  "title": "联系候选人A",
  "note": "今晚前发消息",
  "bucket": "inbox",
  "priority": 3
}
```
预期：任务创建成功，返回 `id`

### 4. 查询任务列表
接口：`GET /api/tasks`
预期：可看到刚创建的任务

### 5. 更新任务
接口：`PATCH /api/tasks/{id}`
示例：
```json
{
  "bucket": "next",
  "priority": 5
}
```
预期：任务字段更新成功

### 6. 完成任务
接口：`POST /api/tasks/{id}/complete`
预期：状态变为已完成

### 7. 重开任务
接口：`POST /api/tasks/{id}/reopen`
预期：任务恢复为未完成状态

### 8. 软删除任务
接口：`DELETE /api/tasks/{id}`
预期：删除成功

### 9. 验证软删除行为
- `GET /api/tasks` 默认不返回已删任务
- `GET /api/tasks?include_deleted=true` 可以查到已删任务

### 10. 批量更新
接口：`POST /api/tasks/batch-update`
建议至少创建 2 条任务后测试

### 11. Assistant capture（首轮 smoke 必测）
接口：`POST /api/assistant/capture`

注意：请求体字段是 `input`，不是 `text`。如果误传成：
```json
{
  "text": "明天提醒我发合同"
}
```
预期会得到 `422`，这不代表服务挂了，而是请求合同不对。

建议 smoke 请求：
```json
{
  "input": "明天提醒我发合同",
  "context": {
    "timezone": "Asia/Shanghai",
    "source": "e2e-smoke",
    "source_ref": "manual-smoke-001",
    "actor": "qa"
  },
  "dry_run": true
}
```

预期：
- 返回 `200`
- 返回 `parsed`
- `dry_run=true` 时不落库，适合先验证解析合同

## 三、Sync 合同 / 回归检查

这些接口已经不是单纯“占位 smoke”，而是桥接联调前的 backend 合同面。除了 200/不报错，更要关注 checkpoint / delivery / 错误快照是否可观测。

### 1. Apple pull
接口：`POST /api/sync/apple/pull`
建议首轮用最小 payload（1 条 upsert 或空 changes）先验证合同，再测冲突路径。
预期：
- 返回 `ok=true`
- 返回 `accepted / applied / conflicts / results[]`
- 返回 `checkpoint.backend_cursor`
- 如果这一步已经失败，不要继续测 push/ack；优先排查 bridge_id、时间字段格式、change payload 结构

### 2. Apple push
接口：`POST /api/sync/apple/push`
预期：
- 返回 `items[]`
- 每条 item 含 `task_id / version / change_id / operation`
- 返回 `checkpoint.last_push_cursor`

首轮 smoke 建议额外盯住：
- 同一条本地变更在重试前后，`change_id` 应保持稳定
- 如果上一轮 ack 是 retryable failed，下一轮重推后 `checkpoint.last_error_code / last_error_message` 仍应保留，方便排障

### 3. Apple ack
接口：`POST /api/sync/apple/ack`
预期：
- 返回 `acked[] / success / failed / conflict`
- success ack 后，`checkpoint.last_acked_change_id` 前进
- failed/conflict ack 后，`checkpoint.last_error_code / last_error_message` 可见
- 若显式传了不存在的 `change_id`，应返回 `409`，不要默默吞掉

### 4. Apple state
接口：`GET /api/sync/apple/state/{bridge_id}`
预期：
- 返回 checkpoint 持久化视图
- 可看到 `pending_delivery_count`
- 可看到 `recent_deliveries[]`
- 若上一轮 ack 失败，空 `acks[]` 的后续心跳请求不应把 `last_error_code / last_error_message` 洗掉
- `recent_deliveries[0]` 最好能直接对上刚才 smoke 的 `task_id + change_id + status`

## 四、异常检查

### 1. 重名项目
重复创建同名项目
预期：返回冲突/错误提示

### 2. 重名标签
重复创建同名标签
预期：返回冲突/错误提示

### 3. 不存在的任务 ID
访问不存在的 task
预期：返回 404

## 五、当前已知边界

- Apple sync 的 backend 合同（pull / push / ack / state）已经在线可测，但真实 Apple Reminders bridge 仍在联调阶段，尚不代表端到端双向同步已经完全收口
- 目前无鉴权，请勿当成正式公开生产服务使用
- 当前是单用户/单实例测试态
- 数据库目前为 SQLite 部署形态，适合当前测试，不是最终形态

## 六、首轮端到端 smoke 建议顺序

建议第一轮整套跑通时，严格按下面顺序执行并记录每一步的请求/响应样本：

1. `GET /api/health`
2. `POST /api/projects`
3. `POST /api/tags`
4. `POST /api/tasks`
5. `PATCH /api/tasks/{id}`
6. `POST /api/tasks/{id}/complete`
7. `POST /api/tasks/{id}/reopen`
8. `DELETE /api/tasks/{id}` + `GET /api/tasks?include_deleted=true`
9. `POST /api/tasks/batch-update`
10. `POST /api/assistant/capture`（先 `dry_run=true`）
11. `POST /api/sync/apple/pull`
12. `POST /api/sync/apple/push`
13. `POST /api/sync/apple/ack`
14. `GET /api/sync/apple/state/{bridge_id}`

如果要压缩成最小首轮 smoke，至少保留 1、4、6、7、8、10、11、12、13、14。

## 七、建议的下一步测试方向

1. 人工完整走一遍任务生命周期
2. 用固定 `bridge_id` 留存一套真实 smoke 样本，便于之后回归比对 checkpoint / delivery 行为
3. 开始对接真实 Apple Reminders sync bridge
4. 后续切 PostgreSQL + 鉴权 + 更正式的生产部署
