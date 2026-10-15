# AI Usage Dashboard

[中文](README.md) | [English](README.en.md)

An AI usage dashboard currently using Codex as its data source. It scans local Codex JSONL files read-only on Windows and displays tokens, tasks, compaction statistics, and Skill instruction reads at `http://127.0.0.1:8765/`. Skill metrics identify commands that read `SKILL.md` in tool calls; they do not prove actual Skill invocation or task success. The application does not read authentication files or upload data, and does not save or display conversation text, full tool arguments, tool output, usernames, or absolute local paths.

This is the English repository overview. The dashboard interface and linked detailed guides are currently primarily in Chinese.

## Repository boundary

This repository tracks the generator, loopback service, static interface, synthetic tests, and operating instructions. `.gitignore` excludes:

- Locally generated HTML, data JSON, incremental caches, and service logs.
- Local statistical history isolated by data source.
- Local source directories in `codex-usage-dashboard.local.psd1`.
- Local acceptance records and original notes containing actual observed usage values.
- Test temporary directories, dependencies, and environment files.

Create local configuration after cloning; the example contains no real paths. Existing configuration, outputs, and caches retain the `codex-usage-dashboard` name for compatibility with installed local data and settings.

## First run

Requires Windows and Windows PowerShell 5.1 or PowerShell 7. Frontend behavior tests also require Node.js.

```powershell
Copy-Item .\codex-usage-dashboard.local.psd1.example .\codex-usage-dashboard.local.psd1
# Edit local configuration; point SourceRoot to your local Codex data directory.
powershell -NoProfile -ExecutionPolicy Bypass -File .\refresh-ai-usage-dashboard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-ai-usage-dashboard-service.ps1
```

Open `http://127.0.0.1:8765/` in a browser. The service listens only on IPv4 loopback. Manual refresh uses `POST /api/refresh` with `X-Codex-Dashboard: 1`.

## Optional automatic maintenance

Running `register-ai-usage-dashboard-maintenance.ps1` registers a short task that runs every minute for the current user. A hidden WScript launcher runs it without a PowerShell console. It checks the loopback port and restarts a missing service. If no data version has been committed in the current hour, it refreshes through the local API and verifies the on-disk version. Failed attempts retry the following minute; the task also runs on battery power. Open pages poll for a new version every 30 seconds. The task runs only while the current user is logged in; it pauses during logout and resumes after login. Use `-Remove` to unregister it.

## Token and request scope

The default “Task usage (including subagents)” scope includes main tasks and ordinary subagents. “Automatic safety review” separately shows guardian approval threads; “All tokens” retains raw usage from both groups. Date, scope, model, and reasoning-effort filters jointly apply to tokens, requests, and context compaction. These raw token shares are not official subscription quota or payment proportions.

Attribution prefers the actual thread identity in `session_meta.id`, using `session_id` only when it is absent. A parent-task identifier is not a child thread's identity. Model and effort are bound to each record when that thread's context and settings are read; earlier tokens can also be attributed from a preceding `turn_context`. Active and archived copies of the same thread are deduplicated by adjacent numeric states. Session counts use actual threads.

Token totals prefer consumption records from `token_count`. When per-request `token_usage_record` entries exist without corresponding consumption records, missing usage is added after deduplication by response identity. Matched responses, duplicate active/archived responses, and numeric states already covered for the same actual thread are not added again. Parent-task identifiers in per-request records do not replace actual thread identity. The statistics notes show the supplementary count.

Event cache version 7 rebuilds older caches from read-only logs because older versions lack actual thread attribution or per-request consumption records. Unclassified old snapshots explicitly show all tokens; refresh before using separate scopes. Invalid core values, dates, identities, states, or durations reject the new snapshot and preserve the last valid statistics.

### Retaining history after log migration

Successfully read compact statistical events are saved in `.codex-usage-dashboard-history/`, isolated by a hash of the normalized `SourceRoot`. If Codex later migrates, archives, or moves source JSONL files, refreshes still merge retained events and deduplicate by thread, response, and numeric state. There is no fixed version-date cutoff and no direct addition of old snapshot totals. When source files return, the current files take precedence and replace retained versions for the same path. History contains only structural identities, time, attribution, and counts, not conversation text, full tool arguments, or raw response IDs. It is not uploaded to GitHub.

If history disappeared before the upgrade but compatible event caches remain in the same output directory, confirm that they belong to the current data source, then run this once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-ai-usage-dashboard-refresh.ps1 -RecoverHistoricalCaches
```

This explicit recovery entry imports only caches compatible with the current version and reader fingerprint. Unknown versions, unknown fingerprints, and corrupt caches are skipped and reported in the statistics notes. Normal refresh does not import old caches unbound to a data source, preventing one source's history from entering another. If committed history is corrupt or incompatible and original logs are missing, refresh fails and preserves the previous valid data instead of silently shortening history. Dates without original logs, compatible caches, or retained events cannot be filled with zeros or guaranteed recoverable.

`.codex-usage-dashboard-cache/` accelerates refresh; HTML and data JSON can be regenerated. After original logs move, `.codex-usage-dashboard-history/` may be the only remaining copy of statistical events. Include it in private local backups and do not treat it as disposable cache. History uses immutable event blocks and a successfully committed manifest. A failed refresh does not overwrite committed history; old blocks are not automatically cleaned up. It is not a backup of original Codex chats. A machine first installed after historical logs migrated cannot reconstruct missing usage from this project's code alone without compatible caches.

Refresh reuses extracted caches per file and rereads changed files in full. Structural events are strictly validated, deduplicated, and aggregated each run. When unchanged-source cache contents, history blocks, file signatures, and parser fingerprints agree and history integrity checks pass, blocks are reused to reduce serialization. Validation and event merging use in-memory .NET helper code. Before sorting, redundant per-request records already covered by consumption records and temporary indexes are released, while per-thread grouping and checks for supplementary old-record usage remain. This adds no installation or background task and does not change statistical definitions or cache version. See [refresh cost](docs/skill-read-metrics.md#刷新成本频率与数据增长) for phase timings and history-write reuse.

## Skill instruction reads

The Skill tab provides a deduplicated overview, daily trends, source distribution, and audit details. Filter and sort by date, name/description, source, and observations; choose the last 7 days, last 30 days, current month, all history, or a custom interval, and manually export the current audit snapshot. Trend charts show a count scale and exact daily values. Read statistics come from `sessions/` and `archived_sessions/` under `SourceRoot`, excluding identifiable guardian and subagent threads, and deduplicate by session, turn, and Skill from the same source. Available-Skill lists, name mentions, and commands that only list paths do not count.

Inspired by [SkillDeck](https://github.com/SpaceZephyr/skilldeck)'s metadata browsing, the inventory reads names and expandable descriptions from current local `SKILL.md` headers. Historical observations, the current directory, and a directory/history comparison help identify items defined now but unobserved in the selected period, or observed historically but absent from the currently bounded directories. The current directory is not an enabled-Skill list or a complete machine-wide installation inventory. Current descriptions do not represent historical versions; missing or conflicting information is marked explicitly. Directory scans do not count as instruction reads and use a separate incremental cache, without adding a service, background task, or external request.

Find Skills through suggested purpose categories and select entries with available current descriptions into a task combination to generate an inspectable, copyable prompt draft. Named combinations save only identifiers and sources in the current browser. Task goals and drafts are not saved to the service or automatically sent or executed. Loading a combination rechecks current material; invalid or conflicting entries require reselection. Prefer existing workflow Skills to duplicate expert orchestration.

Sources distinguish personal, workspace, system, plugin, and unknown entries. The time window is independent of token filters. Overall task and turn counts use a union rather than adding individual Skill counts. Observation hints support human review. Historical observations are not a complete installed inventory, and empty records do not prove a Skill was never used. Cache version 7 supports incremental per-file reuse; the reader-function fingerprint is independent of aggregation/interface changes. The background maintenance chain is unchanged. See [Skill metric definitions](docs/skill-read-metrics.md) for recognition limits, refresh costs, and audit use.

Publishable validation methods appear below. Local acceptance records contain actual usage statistics and remain outside the repository.

Project conventions for dates, default scope, reset, retained views, and Chinese explanations are in [filter and explanation guidelines](docs/dashboard-ui-guidelines.md). Current English Skill descriptions have local Chinese explanations while retaining the originals. If exact matching fails, the original is shown; there is no background translation service.

## Validation

```powershell
node .\tests\Test-Frontend.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Generator.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TokenAttribution.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TokenFallback.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HistoryRetention.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-RefreshPerformance.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Service.ps1 -ServiceHost powershell.exe
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UiContract.ps1
```

The generator, frontend, and service tests above use synthetic data. Optional `tests/Test-Browser.cjs` checks an existing loopback page; `--refresh` performs one real refresh through the page. See [AI-USAGE-DASHBOARD-LOCAL-SERVICE.md](AI-USAGE-DASHBOARD-LOCAL-SERVICE.md) for operating and recovery rules.
