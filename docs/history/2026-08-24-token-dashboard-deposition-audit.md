# Token Dashboard 沉淀审计

- 审计日期：2026-08-24
- 范围：本机 Codex Token 仪表盘与只读统计器
- 结论：`OPERATING / NOT_READY_TO_ARCHIVE`

## archive_readiness

仪表盘已恢复为可用状态，但其计划刷新仍在运行；本任务属于持续维护对象，不应以“已归档”替代运行状态。

## 已回写

1. 刷新器从同一 JSONL 的根级 `session_meta` 继承 session ID，避免无 ID 的 `token_count` 被漏计。
2. 统计口径明确为：`Total = Cached Input + Fresh Input + Output`，其中 `Fresh Input = Input - Cached Input`。
3. `Reasoning` 改为 `Output` 内部占比，不计入第四个可相加类别，也不加入 Total。
4. 页面保持本地离线、只读原始日志、计划任务短跑刷新；不读取认证文件或正文内容。

## 新建或更新的候选

| 候选 | 状态 | 适用范围 | 晋升条件 | 回滚 |
|---|---|---|---|---|
| TOKEN-DASHBOARD-ACCOUNTING-v0 | 任务内候选 | 本机 Codex JSONL 统计器 | 后续 2 次独立刷新均通过 schema 与总量复核 | 移除候选规则，回到重新抽样审计 |

候选内容仅包括 session ID 继承、数值状态去重、三类可加构成与 Reasoning 子集规则；不改变用户级画像、全局 Skill 或 Codex 配置。

## 画像观察

无。此次是对输出格式和证据边界的即时纠正，不足以形成稳定用户级偏好新增项。

## 无需沉淀

- 不新增多 Tab、常驻服务或本地端口。
- 不升级为全局自动化、全局 dashboard 模板或生产级实时监控。

## 仍需用户决定

无。当前保留每小时、本地、非服务式刷新；若未来需要更短刷新间隔，应先验证增量缓存后再调整。

## 验证结果

- 已验证页面包含非零聚合数据并保留筛选功能。
- 已验证构成视图不再将 Reasoning 与三类可加 Token 并列相加。
- 未修改任何原始 JSONL；未读取认证文件或对话正文。
