# Regression for parent/child interleaving, context-only attribution and duplicate logs.
# All inputs are synthetic; original Codex session files are never touched.
[CmdletBinding()]
param(
  [string]$Generator = '',
  [string]$TestOutputRoot = (Join-Path ([IO.Path]::GetTempPath()) 'codex-token-attribution-tests')
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
$engine = (Get-Process -Id $PID).Path
$runRoot = Join-Path $TestOutputRoot ([Guid]::NewGuid().ToString('N'))
$source = Join-Path $runRoot 'synthetic-codex'
$output = Join-Path $runRoot 'generated'
$sessions = Join-Path $source 'sessions'
$archives = Join-Path $source 'archived_sessions'
New-Item -ItemType Directory -Path $sessions, $archives, $output -Force | Out-Null
$checks = 0
function Check([string]$Name, $Actual, $Expected) {
  if ($Actual -ne $Expected) { throw "$Name expected [$Expected], got [$Actual]" }
  $script:checks++
}
function Event([string]$At, [string]$Type, $Payload) {
  [ordered]@{ timestamp = $At; type = $Type; payload = $Payload }
}
function Token([string]$At, [long]$InputTokens, [long]$OutputTokens, [long]$Cumulative) {
  Event $At 'event_msg' ([ordered]@{ type = 'token_count'; session_id = 'fixture-logical-parent'; info = [ordered]@{
    last_token_usage = [ordered]@{ input_tokens = $InputTokens; cached_input_tokens = 10; output_tokens = $OutputTokens; reasoning_output_tokens = 2; total_tokens = $InputTokens + $OutputTokens }
    total_token_usage = [ordered]@{ input_tokens = $Cumulative; cached_input_tokens = 10; output_tokens = 0; reasoning_output_tokens = 2; total_tokens = $Cumulative }
  } })
}
function Context([string]$At, [string]$Model, [string]$Effort) {
  Event $At 'turn_context' ([ordered]@{ turn_id = 'fixture-shared-turn'; model = $Model; effort = $Effort })
}
function Write-Events([string]$Path, [object[]]$Events) {
  $lines = @($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 10 -Compress })
  [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}
$mainPath = Join-Path $sessions 'main.jsonl'
Write-Events $mainPath @(
  (Event '2026-10-12T15:59:50Z' 'session_meta' @{ id = 'fixture-main-thread'; session_id = 'fixture-logical-parent' }),
  (Event '2026-10-12T15:59:54Z' 'event_msg' @{ type = 'task_started'; turn_id = 'fixture-shared-turn' }),
  (Context '2026-10-12T15:59:55Z' 'fixture-sol' 'max'),
  (Token '2026-10-12T15:59:59Z' 100 10 110),
  (Token '2026-10-12T16:00:02Z' 100 10 110),
  (Token '2026-10-12T16:00:05Z' 140 20 270),
  (Context '2026-10-12T16:00:07Z' 'fixture-luna' 'medium'),
  (Token '2026-10-12T16:00:10Z' 50 5 325),
  (Event '2026-10-12T16:00:11Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'fixture-shared-turn'; duration_ms = 17000; time_to_first_token_ms = 1000 })
)
Write-Events (Join-Path $sessions 'reviewer.jsonl') @(
  (Event '2026-10-12T15:59:50Z' 'session_meta' @{ id = 'fixture-review-thread'; session_id = 'fixture-logical-parent'; parent_thread_id = 'fixture-main-thread'; source = @{ subagent = @{ other = 'guardian' } }; thread_source = 'guardian_review' }),
  (Event '2026-10-12T15:59:53Z' 'event_msg' @{ type = 'task_started'; turn_id = 'fixture-shared-turn' }),
  (Context '2026-10-12T15:59:56Z' 'codex-auto-review' 'low'),
  (Token '2026-10-12T15:59:57Z' 40 5 45),
  (Event '2026-10-12T16:00:00Z' 'event_msg' @{ type = 'thread_settings_applied'; thread_settings = @{ model = 'codex-auto-review'; reasoning_effort = 'low' } }),
  (Token '2026-10-12T16:00:03Z' 40 5 90),
  (Event '2026-10-12T16:00:04Z' 'event_msg' @{ type = 'compacted'; window_id = 'fixture-review-window' }),
  (Event '2026-10-12T16:00:06Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'fixture-shared-turn'; duration_ms = 13000 })
)
Write-Events (Join-Path $sessions 'helper.jsonl') @(
  (Event '2026-10-12T16:00:06Z' 'session_meta' @{ id = 'fixture-helper-thread'; session_id = 'fixture-logical-parent'; parent_thread_id = 'fixture-main-thread'; source = @{ subagent = @{ other = 'worker' } } }),
  (Event '2026-10-12T16:00:07Z' 'event_msg' @{ type = 'task_started'; turn_id = 'fixture-shared-turn' }),
  (Context '2026-10-12T16:00:08Z' 'fixture-worker' 'high'),
  (Token '2026-10-12T16:00:09Z' 100 10 110),
  (Event '2026-10-12T16:00:12Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'fixture-shared-turn'; duration_ms = 5000 })
)
Copy-Item -LiteralPath $mainPath -Destination (Join-Path $archives 'main-copy.jsonl')
$sourceHashes = @(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object { @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
$mutex = 'Local\CodexTokenAttribution_' + [Guid]::NewGuid().ToString('N')
function Run([string]$Scenario, [int]$Reused, [int]$Reparsed) {
  $messages = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $generatorPath -SourceRoot $source -OutputRoot $output -MutexName $mutex -AsOfDate '2026-10-13' 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ("$Scenario generator failed: " + ($messages -join [Environment]::NewLine)) }
  Check "$Scenario generator exit" $LASTEXITCODE 0
  $data = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $output 'codex-usage-dashboard-data.json')))
  Check "$Scenario scope schema" $data.usageScopeSchema 1
  Check "$Scenario cache reused" $data.refresh.reused $Reused
  Check "$Scenario source reparsed" $data.refresh.reparsed $Reparsed
  Check "$Scenario all raw tokens retained" ($data.usage | Measure-Object total -Sum).Sum 525
  Check "$Scenario task tokens" ($data.usage | Where-Object scope -eq 'task' | Measure-Object total -Sum).Sum 435
  Check "$Scenario review tokens" ($data.usage | Where-Object scope -eq 'auto_review' | Measure-Object total -Sum).Sum 90
  Check "$Scenario main Sol tokens" ($data.usage | Where-Object model -eq 'fixture-sol' | Measure-Object total -Sum).Sum 270
  Check "$Scenario model switch tokens" ($data.usage | Where-Object model -eq 'fixture-luna' | Measure-Object total -Sum).Sum 55
  Check "$Scenario ordinary child tokens retained" ($data.usage | Where-Object model -eq 'fixture-worker' | Measure-Object total -Sum).Sum 110
  Check "$Scenario no unresolved model" @($data.usage | Where-Object model -eq 'unknown').Count 0
  Check "$Scenario reviewer cannot claim main model" @($data.usage | Where-Object { $_.scope -eq 'auto_review' -and $_.model -ne 'codex-auto-review' }).Count 0
  Check "$Scenario main cannot inherit reviewer effort" @($data.usage | Where-Object { $_.model -eq 'fixture-sol' -and $_.effort -ne 'max' }).Count 0
  Check "$Scenario actual thread count" @($data.usage.session | Sort-Object -Unique).Count 3
  Check "$Scenario shared turn remains three actual requests" @($data.tasks).Count 3
  Check "$Scenario ordinary task requests" @($data.tasks | Where-Object scope -eq 'task').Count 2
  Check "$Scenario review request count" @($data.tasks | Where-Object scope -eq 'auto_review').Count 1
  Check "$Scenario model attribution on completed request" @($data.tasks | Where-Object { $_.model -eq 'fixture-luna' -and $_.effort -eq 'medium' -and $_.startedDate -eq '2026-10-12' -and $_.date -eq '2026-10-13' }).Count 1
  Check "$Scenario review compaction scope" @($data.compactions | Where-Object { $_.scope -eq 'auto_review' -and $_.model -eq 'codex-auto-review' }).Count 1
  Check "$Scenario Shanghai midnight boundary" ($data.usage | Where-Object date -eq '2026-10-12' | Measure-Object total -Sum).Sum 155
  Check "$Scenario duplicate states within actual thread" $data.duplicates 5
  Check "$Scenario numeric accounting" @($data.usage | Where-Object { $_.total -ne ($_.input + $_.output) -or $_.input -ne ($_.cached + $_.fresh) }).Count 0
  $json = [IO.File]::ReadAllText((Join-Path $output 'codex-usage-dashboard-data.json'))
  Check "$Scenario no raw thread IDs or local paths in data" ($json -match 'fixture-logical-parent|fixture-main-thread|fixture-review-thread|fixture-helper-thread|synthetic-codex') $false
  foreach ($item in $sourceHashes) { Check "$Scenario source unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash }
}
Run 'cold' 0 4
Run 'warm' 4 0
# A v5 snapshot lacks source-thread attribution; replacing only its manifest is unsafe.
$cache = Join-Path $output '.codex-usage-dashboard-cache'
$manifestPath = Join-Path $cache 'manifest.json'
$manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath))
$manifest.version = 5
[IO.File]::WriteAllText($manifestPath, (ConvertTo-Json $manifest -Depth 8 -Compress))
Run 'v5-rebuild' 0 4
# Even a matching v7 record must be reparsed when its attribution is incomplete.
$manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath))
$recordPath = Join-Path $cache ($manifest.files[0].cache + '.json')
$record = ConvertFrom-Json ([IO.File]::ReadAllText($recordPath))
$firstToken = $record.events | Where-Object k -eq 'token_count' | Select-Object -First 1
$firstToken.sc = $null
[IO.File]::WriteAllText($recordPath, (ConvertTo-Json $record -Depth 8 -Compress))
Run 'invalid-attribution-rebuild' 3 1
[pscustomobject]@{ passed = $true; assertions = $checks; scenarios = 4; engine = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress
