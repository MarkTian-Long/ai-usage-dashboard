# AI Usage Dashboard

AI 使用看板，当前数据来源为 Codex。在 Windows 本地只读扫描 Codex JSONL，在 `http://127.0.0.1:8765/` 展示 Token、任务、压缩统计与 Skill 说明读取。Skill 指标仅从工具调用中识别读取 `SKILL.md` 的命令，不代表实际调用或任务成功。它不读取认证文件、不上传数据，也不保存或显示会话正文、完整工具参数、工具输出、用户名或本机绝对路径。

## 仓库边界

本仓库追踪生成器、回环服务、静态界面、合成测试和运行说明。下列内容均被 `.gitignore` 排除：

- 本机生成的 HTML、数据 JSON、增量缓存和服务日志；
- `codex-usage-dashboard.local.psd1` 中的本机源目录；
- 本机验收记录和含实际观测量值的原始说明；
- 测试临时目录、依赖目录和环境文件。

因此，克隆项目后需要先创建本地配置；示例文件不包含真实路径。现有配置、生成物和缓存保留 `codex-usage-dashboard` 名称，兼容已安装的本机数据和设置。

## 首次运行

前提：Windows、Windows PowerShell 5.1 或 PowerShell 7。前端行为测试还需要 Node.js。

```powershell
Copy-Item .\codex-usage-dashboard.local.psd1.example .\codex-usage-dashboard.local.psd1
# 编辑本地配置；SourceRoot 指向本机 Codex 数据目录。
powershell -NoProfile -ExecutionPolicy Bypass -File .\refresh-ai-usage-dashboard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-ai-usage-dashboard-service.ps1
```

浏览器打开 `http://127.0.0.1:8765/`。服务只监听 IPv4 loopback；手动刷新使用 `POST /api/refresh` 并携带 `X-Codex-Dashboard: 1`。

## 自动维护（可选）

运行 `register-ai-usage-dashboard-maintenance.ps1` 会为当前用户登记每分钟一次的短时计划任务。它通过隐藏的 WScript 启动器运行，不弹出 PowerShell 控制台；检查回环端口并在服务缺失时重新启动。若当前小时尚无已提交数据版本，则通过本地 API 刷新并核对磁盘版本。失败后下一分钟重试，任务在电池供电时也会运行。已打开页面每 30 秒轮询一次新版本。此任务只在当前用户已登录时运行；注销期间不运行，重新登录后恢复。用 `-Remove` 可移除任务。

## Skill 说明读取

Skill 页签提供去重总览、每日趋势、来源分布和审计明细；可按日期、名称/简介、来源、观察项筛选并排序，支持近 7 天、近 30 天、本月、全部历史或自定义区间，以及手动导出当前审计快照。趋势图显示数量刻度并可查看逐日精确读数。读取统计来自 `SourceRoot` 下的 `sessions/` 与 `archived_sessions/`，排除可识别的 guardian 和子代理；按会话、轮次与同来源 Skill 去重。可用清单、名称提及和只列路径的命令均不计数。

清单结合 [SkillDeck](https://github.com/SpaceZephyr/skilldeck) 的元数据浏览思路，从当前本地 `SKILL.md` 头部取得名称与可展开简介。支持历史观测、当前目录和目录/历史对照，帮助识别当前有定义但本期未观测、历史曾见但当前限定目录未找到的项目。当前目录不是启用清单或全机安装全集；说明不代表历史版本，缺失或冲突明确标注。目录扫描不算读取次数，使用独立增量缓存，不引入新的服务、后台任务或外部请求。

可按用途候选分类查找 Skill，并将当前有可用说明的项目选入任务组合，生成可检查和复制的口令草稿。命名组合只保存标识和来源到当前浏览器；任务目标与草稿不保存到服务，不自动发送或执行。加载组合时重新检查当前资料，失效或冲突项需要重新选择。优先复用已有流程 Skill，避免另建重复的专家编排。

来源区分个人、工作区、系统、插件和未知。窗口独立于 Token 筛选；整体任务与轮次按并集计算，不将每个 Skill 的人数/轮次相加。观察提示用于人工复核，历史观测列表不代表全部安装清单，空记录不等于从未使用。缓存版本 5 按文件增量复用，读取函数指纹独立于汇总/界面改动；Token 口径与后台维护链路不变。详细识别边界、刷新成本和审计用法见 [Skill 统计口径](docs/skill-read-metrics.md)。

可发布的验证方法见下方“验证”。本机验收记录含真实使用统计，仅保留在本地，不进入仓库。

日期筛选、默认范围、重置、视图保留及中文释义的项目约定见 [筛选与说明展示规范](docs/dashboard-ui-guidelines.md)。当前英文简介提供本地中文释义，保留原文，精确匹配失效时回退原文；没有后台翻译服务。

## 验证

```powershell
node .\tests\Test-Frontend.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Generator.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Service.ps1 -ServiceHost powershell.exe
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UiContract.ps1
```

上述生成器、前端和服务测试使用合成数据。可选的 `tests/Test-Browser.cjs` 验收现有回环页面，使用 `--refresh` 时通过页面执行一次真实刷新。详细运行与恢复规则见 [AI-USAGE-DASHBOARD-LOCAL-SERVICE.md](AI-USAGE-DASHBOARD-LOCAL-SERVICE.md)。
