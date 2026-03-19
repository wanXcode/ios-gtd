# Bridge E2E 手工测试说明

这份文档服务“开始整套跑通测试”的第 4 步：
在真机 compile-prep 完成后，按固定顺序做一次最小闭环联调。

## 建议顺序

先保证 `docs/BRIDGE_COMPILE_PREP.md` 已经通过，再做这里。

## 场景 A：Apple → backend

1. 在 Mac 上选定 bridge 同步的 Reminders list。
2. 新建一条 reminder，例如：`E2E Apple Pull Smoke`。
3. 运行：

```bash
cd mac-sync-bridge
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

4. 到 backend 验证：
   - task 已创建
   - 标题正确
   - due/completed/list 等字段未明显丢失
5. 记录 backend 返回的 task id / mapping 结果。

## 场景 B：backend → Apple

1. 直接调 backend API 新建或修改一条 task。
2. 运行：

```bash
cd mac-sync-bridge
swift run BridgeApp --config ~/Library/Application\ Support/GTD/mac-sync-bridge/config.json --once
```

3. 回到 Reminders 验证：
   - 标题已更新/创建
   - due / notes / completion 等关键字段已回写
4. 再执行一次 `--once`，确认不会重复创建。

## 场景 C：ack / retry / checkpoint

1. 先跑一次 backend → Apple push。
2. 制造一次可控失败（例如临时停 backend 或改错 token）。
3. 再跑一轮，观察：
   - stdout/stderr 是否有失败信息
   - sqlite checkpoint 是否保留最近错误状态
   - backend `/api/sync/apple/state/{bridge_id}` 是否仍能看见 checkpoint / recent deliveries
4. 恢复网络或 token 后，再跑一轮，观察是否恢复。

## 场景 D：LaunchAgent 常驻

1. 安装 LaunchAgent。
2. 修改 Apple Reminders 一条已同步任务。
3. 等待一个 `syncIntervalSeconds` 周期。
4. 验证 backend 是否自动收敛，不依赖手动执行命令。
5. 再做一条 backend 改动，确认常驻 loop 也能自动回写。

## 每轮至少记录这些

- 时间
- `bridgeID`
- backend 地址
- config 路径
- sqlite 路径
- stdout/stderr 摘要
- backend state 接口返回
- 是否重复创建 / 是否出现 conflict / 是否出现 retry

## 结束标准

这轮 E2E 至少要拿到下面 4 个结论：

- Apple 新建/修改能上送 backend
- backend 新建/修改能回写 Apple
- 失败后有 checkpoint / 错误面可排查
- 常驻入口（LaunchAgent）不是纸面方案，实际能拉起并工作

做到这里，才算真正开始进入“整套跑通测试”，而不是还停留在文档就绪阶段。
