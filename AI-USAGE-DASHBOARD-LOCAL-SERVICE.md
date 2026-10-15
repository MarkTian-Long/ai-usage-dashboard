# AI 使用看板运行与恢复

当前目录是运行主版本，见 CANONICAL-RUNTIME.md。页面入口为 http://127.0.0.1:8765/ 。

## 已核验的入口

- 页面：GET /；状态：GET /api/status；数据：GET /api/data。
- 手动刷新：POST /api/refresh，必须带 X-Codex-Dashboard: 1。
- 仅绑定 127.0.0.1，端口默认 8765；占用时启动报错，不切换端口。
- 当前用户的 `Codex Usage Dashboard Maintenance` 计划任务每分钟通过 `tools/run-dashboard-maintenance-hidden.vbs` 隐藏运行一次 `run-ai-usage-dashboard-maintenance.ps1`，检查回环端口并在服务缺失时启动服务；当前小时没有已提交数据版本时通过本地刷新 API 触发汇总，失败后下一分钟重试。互斥量避免并发维护。任务允许电池供电运行，错过运行时间后尽快补跑。WScript 等待脚本结束并将退出码返回计划任务。
- 页面每 30 秒检查状态与数据版本；需要立即刷新时使用页面按钮或 `POST /api/refresh`。并发刷新仍由服务返回 409 防重入。维护脚本将刷新受理、提交或失败写入 `codex-usage-dashboard-maintenance.log`，不记录会话内容。
- 计划任务为当前用户交互式登录模式：锁屏和恢复已有会话期间仍可运行，注销期间不运行，重新登录后恢复。核验时检查任务上次结果、端口、API 和数据版本，不能只检查任务存在。
- 本机配置可选 `PowerShellPath` 指向已有的本地 `pwsh.exe` 或 `powershell.exe`；维护启动与刷新子进程都读取该项。路径失效或未填写时依次使用 PATH 中的 `pwsh`、Windows PowerShell。修改该项后先等待当前刷新结束，再重启服务；无需重新登记计划任务。
- 维护启动器可由计划任务以较低优先级运行；HTTP 服务启动时将自身的 Idle/BelowNormal 提升为普通 Normal，刷新子进程继承普通优先级。仅影响看板自己的进程，不修改其他应用、系统调度或计划任务配置。

## 刷新状态

- refreshing：子进程仍运行，页面继续显示最后成功快照；并发刷新请求返回 409。
- ready：最近刷新退出码为 0，数据文件版本已更新且 JSON 校验通过。服务刚启动时加载磁盘已有合法快照。
- failed：启动或刷新失败、退出后没有新数据，或新数据无效。状态返回原因；服务运行期间旧成功快照仍可读取，可再次点击刷新。
- updated 表示最后成功数据版本，失败不会把未确认数据发布为成功快照。
- 浏览器空闲时每 30 秒检查更新，手动刷新时每 250 毫秒查询完成状态。按钮在完整刷新生命周期内保持忙碌；新数据成功载入并核对版本后才显示完成，历史筛选保留。短暂状态连接失败会有限重试，不重复提交刷新。
- 客户端请求头读取有总时限、大小上限及有界待处理队列；空闲预连接和部分请求头不会逐个阻塞后续状态请求。PowerShell 7 校验快照 JSON 时不构造完整 PowerShell 对象图，旧宿主保留兼容路径。

## 源码、缓存与数据范围

- refresh-ai-usage-dashboard.ps1 负责只读扫描、事件解析、文件缓存和汇总。
- web/dashboard.html、web/dashboard.css、web/dashboard.js 是页面源；生成器将其内联到 codex-usage-dashboard.html，无需外部 CDN。
- JSONL 来自 SourceRoot、默认 Codex 目录或既有 CODEX_HOME。只提取结构性事件与数值统计；Skill 代理指标额外识别真实工具调用中读取 SKILL.md 的字面量命令，仅保存脱敏标识与计数，不保存完整工具参数。不输出对话正文，不访问认证文件，不上传数据。
- .codex-usage-dashboard-cache/、HTML、数据 JSON 是可重建生成物。不要直接编辑。`.codex-usage-dashboard-history/` 则是按数据源隔离的持久统计事件；原日志迁移后可能是唯一的统计副本，应保留并随私有备份保存。它不是原始聊天备份，不能作为普通缓存清理。
- 缓存版本 7 保存实际线程身份、逐条模型/强度/范围，以及逐请求消耗和响应哈希。对已匹配响应及已覆盖数值状态不补计，缺失消耗按响应身份全局去重后补计。延续 UTC 日期解析、缺失时长及 Skill 说明读取语义，源文件清单使用路径哈希。按文件长度、修改时间与读取函数指纹复用；仅汇总或 web 界面修改不触发全量重读。v5 缺少线程归属，v6 缺少逐请求消耗，均必须从只读日志重建，不能热迁移。旧版本、未知指纹、空对象、缺失归属或损坏缓存会重新解析；Skill 窗口每次刷新重新计算。
- Token、请求与压缩共享“任务用量（含子代理）／自动安全审查／全部 Token”筛选，默认任务范围。按实际线程 ID 绑定上下文和设置，父任务的 session_id 不用于混合子线程。全部 Token 保留两类原始用量；不转换为官方套餐或付费额度。
- 每次汇总仍枚举全部源文件元数据。UTF-8 日志增长且完整旧前缀 SHA、事件缓存与续读状态绑定一致时只解析追加内容；其他变化从头解析，未变化的读精简缓存。续读状态用当前 Windows 用户 DPAPI 密封，仅作可重建加速。当前存在文件优先，原路径已缺失的统计从持久历史加载，统一进行响应与消耗去重。数据 JSON/HTML/清单覆盖写入，不按次数留完整快照。源文件迁移可能留下孤立缓存；普通刷新不导入未绑定来源的孤立缓存。确认它们属于当前源后，用 `run-ai-usage-dashboard-refresh.ps1 -RecoverHistoricalCaches` 显式恢复兼容事件；失败项不会伪装成已恢复。已提交历史损坏或不兼容且原日志缺失时刷新失败，上一份有效数据保留。日志目前无轮转。详细口径见 README 与 docs/skill-read-metrics.md。
- codex-usage-dashboard-service.log 只记录受控运行消息与退出码，不记录原始会话或异常正文。

## 修改与验证

在本目录执行：

    node .\tests\Test-Frontend.cjs
    pwsh -NoProfile -File .\tests\Test-Generator.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Generator.ps1
    pwsh -NoProfile -File .\tests\Test-TokenFallback.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TokenFallback.ps1
    pwsh -NoProfile -File .\tests\Test-TokenAttribution.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TokenAttribution.ps1
    pwsh -NoProfile -File .\tests\Test-Service.ps1 -ServiceHost pwsh
    pwsh -NoProfile -File .\tests\Test-Service.ps1 -ServiceHost powershell.exe
    pwsh -NoProfile -File .\tests\Test-UiContract.ps1

新增历史留存回归用 `tests/Test-HistoryRetention.ps1`，分别在 PowerShell 5.1 与 7 运行。

服务测试使用随机临时端口和合成数据；生成器测试使用独立输入、输出及互斥量，不修改生产日志。还应浏览器验证桌面三块占比横排、390px 单列、历史筛选保留和一次真实刷新成功。

## 停用与恢复

临时重启前先核对刷新状态，等待本次刷新结束；强制结束服务不会自动结束它的刷新子进程，遗留子进程可能继续占用生成器互斥锁。仅结束实际监听 8765 且命令行指向本目录服务的进程；如必须处理中断的子进程，另核对父进程及生成器完整命令行，不结束其他 PowerShell 进程。下一分钟的维护任务会恢复服务，也可运行 `schtasks /Run /TN "Codex Usage Dashboard Maintenance"` 立即检查。

如需长期停用，运行 `register-ai-usage-dashboard-maintenance.ps1 -Remove` 移除单一自动维护任务，并定点结束服务进程。

刷新失败时先查看页面原因和本地服务日志，再重试。修改代码后如需回滚，应一并恢复生成器、服务与 web/ 模板，并重新生成缓存及页面，避免跨版本混用。
