# 当前运行版：唯一入口

当前 AI 使用看板只通过 `http://127.0.0.1:8765/` 使用。当前用户已登录时，`Codex Usage Dashboard Maintenance` 计划任务每分钟通过隐藏的 WScript 启动器运行一次短脚本；服务缺失时启动服务，当前小时没有已提交版本时触发本地刷新并核对版本。单次任务或服务退出后可在下一轮重试；注销期间任务不运行。服务不监听非回环地址，也不上传数据。

## 修改边界

- 可修改的运行源：`refresh-ai-usage-dashboard.ps1`、`start-ai-usage-dashboard-service.ps1`、`run-ai-usage-dashboard-refresh.ps1`，以及 `web/dashboard.html`、`web/dashboard.css`、`web/dashboard.js`。生成器将三份网页源内联成自包含 HTML。
- 生成物：`codex-usage-dashboard.html`、`codex-usage-dashboard-data.json`、`.codex-usage-dashboard-cache/`。不要直接编辑；下次刷新会覆盖它们。
- 自动维护只通过 `register-ai-usage-dashboard-maintenance.ps1` 登记当前用户计划任务。迁移本目录后重新运行该脚本；必须以端口、API、任务结果和新监听进程验证，不能只以任务存在判断恢复。数据目录来自被忽略的 `codex-usage-dashboard.local.psd1`。
- UI 变更完成后必须运行 `tests/Test-UiContract.ps1`、`node tests/Test-Frontend.cjs`，并在浏览器验证桌面三块占比横排、390px 单列和筛选保留。后端变更运行 `tests/Test-Generator.ps1`、`tests/Test-Service.ps1`，兼容 PowerShell 5.1 与 7。

## 当前 UI 契约

在 Token 总览中，Token 构成占比、模型 Token 占比和推理强度 Token 占比横向展示于柱状图上方；Token 构成占比必须包含 Cache、Fresh、Output 和 Reasoning（标明为 Output 子集）。

Token 与请求/效率默认“任务用量（含子代理）”；自动安全审查单独选择，全部 Token 保留两类用量。模型与强度按实际线程及其上下文绑定，父任务标识不用于混合主线程和审查线程。原始 Token 占比不代表官方套餐额度。旧快照不能假装已按新口径分类，须明确提示刷新。

缺少对应 Token 消耗事件的逐请求记录按响应身份去重补计，已匹配响应与已覆盖数值状态不再累加；统计说明显示补计量。核心快照类型、数值算式、日期、身份、状态或时长非法时保留上一份有效数据。普通模型切换清除不适用强度；Token/请求趋势保留实际日历间距，空白日表示无可观测记录，活跃日日均定义不变。

Skill 页签延续 `dashboard-skill-contract-v1` 的代理指标边界：上海时区、主任务去重、来源分开，不受 Token 筛选影响。增加独立日期/名称/来源/观察项筛选，总览、趋势、明细和审计导出使用同一范围；整体任务/轮次按并集去重。旧快照与没有可识别记录分别提示，不能都解释为零使用。历史列表不代表完整安装清单，观察提示不直接作退役结论。详见 [统计口径](docs/skill-read-metrics.md)。
