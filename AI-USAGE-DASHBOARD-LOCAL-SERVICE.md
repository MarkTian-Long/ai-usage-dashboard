# AI 使用看板运行与恢复

当前目录是运行主版本，见 CANONICAL-RUNTIME.md。页面入口为 http://127.0.0.1:8765/ 。

## 已核验的入口

- 页面：GET /；状态：GET /api/status；数据：GET /api/data。
- 手动刷新：POST /api/refresh，必须带 X-Codex-Dashboard: 1。
- 仅绑定 127.0.0.1，端口默认 8765；占用时启动报错，不切换端口。
- 当前用户的 `Codex Usage Dashboard Maintenance` 计划任务每分钟通过 `tools/run-dashboard-maintenance-hidden.vbs` 隐藏运行一次 `run-ai-usage-dashboard-maintenance.ps1`，检查回环端口并在服务缺失时启动服务；当前小时没有已提交数据版本时通过本地刷新 API 触发汇总，失败后下一分钟重试。互斥量避免并发维护。任务允许电池供电运行，错过运行时间后尽快补跑。WScript 等待脚本结束并将退出码返回计划任务。
- 页面每 30 秒检查状态与数据版本；需要立即刷新时使用页面按钮或 `POST /api/refresh`。并发刷新仍由服务返回 409 防重入。维护脚本将刷新受理、提交或失败写入 `codex-usage-dashboard-maintenance.log`，不记录会话内容。
- 计划任务为当前用户交互式登录模式：锁屏和恢复已有会话期间仍可运行，注销期间不运行，重新登录后恢复。核验时检查任务上次结果、端口、API 和数据版本，不能只检查任务存在。

## 刷新状态

- refreshing：子进程仍运行，页面继续显示最后成功快照；并发刷新请求返回 409。
- ready：最近刷新退出码为 0，数据文件版本已更新且 JSON 校验通过。服务刚启动时加载磁盘已有合法快照。
- failed：启动或刷新失败、退出后没有新数据，或新数据无效。状态返回原因；服务运行期间旧成功快照仍可读取，可再次点击刷新。
- updated 表示最后成功数据版本，失败不会把未确认数据发布为成功快照。
- 浏览器每 30 秒检查更新。按钮在完整刷新生命周期内保持忙碌；新数据成功载入后才显示完成，历史筛选保留。
- 客户端请求读取有总时限和大小上限，异常连接会关闭，不会无限阻塞后续访问。

## 源码、缓存与数据范围

- refresh-ai-usage-dashboard.ps1 负责只读扫描、事件解析、文件缓存和汇总。
- web/dashboard.html、web/dashboard.css、web/dashboard.js 是页面源；生成器将其内联到 codex-usage-dashboard.html，无需外部 CDN。
- JSONL 来自 SourceRoot、默认 Codex 目录或既有 CODEX_HOME。只提取结构性事件与数值统计；Skill 代理指标额外识别真实工具调用中读取 SKILL.md 的字面量命令，仅保存脱敏标识与计数，不保存完整工具参数。不输出对话正文，不访问认证文件，不上传数据。
- .codex-usage-dashboard-cache/、HTML、数据 JSON 是可重建生成物。不要直接编辑。
- 缓存版本 5 延续 UTC 日期解析及缺失时长语义，保存 Skill 说明读取事件，源文件清单使用路径哈希。按文件长度、修改时间与读取函数指纹复用；仅汇总或 web 界面修改不触发全量重读。已验收的旧 v5 全文指纹可一次性热迁移。旧版本、未知指纹、空对象或损坏缓存会重新解析；Skill 窗口每次刷新重新计算。
- 每次汇总仍枚举全部源文件元数据，变化文件从头解析，未变化的读精简缓存，属于文件级增量。数据 JSON/HTML/清单覆盖写入，不按次数留完整快照；源文件迁移可能留下孤立缓存，日志目前无轮转。刷新成本字段用于观察文件复用与体积，详细口径见 docs/skill-read-metrics.md。
- codex-usage-dashboard-service.log 只记录受控运行消息与退出码，不记录原始会话或异常正文。

## 修改与验证

在本目录执行：

    node .\tests\Test-Frontend.cjs
    pwsh -NoProfile -File .\tests\Test-Generator.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Generator.ps1
    pwsh -NoProfile -File .\tests\Test-Service.ps1 -ServiceHost pwsh
    pwsh -NoProfile -File .\tests\Test-Service.ps1 -ServiceHost powershell.exe
    pwsh -NoProfile -File .\tests\Test-UiContract.ps1

服务测试使用随机临时端口和合成数据；生成器测试使用独立输入、输出及互斥量，不修改生产日志。还应浏览器验证桌面三块占比横排、390px 单列、历史筛选保留和一次真实刷新成功。

## 停用与恢复

临时重启仅结束实际监听 8765 且命令行指向本目录服务的进程；不要结束所有 PowerShell 进程。下一分钟的维护任务会恢复它，也可运行 `schtasks /Run /TN "Codex Usage Dashboard Maintenance"` 立即检查。

如需长期停用，运行 `register-ai-usage-dashboard-maintenance.ps1 -Remove` 移除单一自动维护任务，并定点结束服务进程。

刷新失败时先查看页面原因和本地服务日志，再重试。修改代码后如需回滚，应一并恢复生成器、服务与 web/ 模板，并重新生成缓存及页面，避免跨版本混用。
