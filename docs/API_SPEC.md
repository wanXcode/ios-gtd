# API Spec (MVP Draft)

Base URL: `/api`

## Health

### GET /health
返回服务健康状态。

## Projects

### GET /projects
返回项目列表，按创建时间倒序。

### POST /projects
请求体：

```json
{
  "name": "招聘",
  "description": "招聘相关任务"
}
```

## Tags

### GET /tags
返回标签列表，按名称排序。

### POST /tags
请求体：

```json
{
  "name": "work",
  "color": "blue"
}
```

## Tasks

### GET /tasks
支持筛选参数：

- `bucket`
- `status`
- `project_id`
- `due_before`
- `due_after`
- `updated_after`
- `q`

### POST /tasks
请求体示例：

```json
{
  "title": "给客户回电话",
  "note": "讨论合同",
  "bucket": "inbox",
  "priority": 5,
  "last_modified_by": "chat"
}
```

### GET /tasks/{id}
返回单个任务详情。

### PATCH /tasks/{id}
支持部分字段更新，包括 `tag_ids`。

### POST /tasks/{id}/complete
将任务置为 `completed`，并自动切换到 `done` bucket。

### DELETE /tasks/{id}
物理删除任务（MVP 阶段）。后续可升级为软删除。
