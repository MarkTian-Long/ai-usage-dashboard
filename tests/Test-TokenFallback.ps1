# Synthetic integration counterexamples for request usage missing token_count.
# Never reads the real Codex home or writes its logs or production dashboard.
[CmdletBinding()]
param(
  [string]$Generator = '',
  [string]$ExpectedGeneratorSha256 = '',
  [string]$TestOutputRoot = (Join-Path $PSScriptRoot 'service-fixtures\token-fallback')
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
$generatorHash = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedGeneratorSha256 -and $generatorHash -ne $ExpectedGeneratorSha256) {
  throw 'Generator SHA256 differs from the explicitly pinned test source.'
}
$engine = (Get-Process -Id $PID).Path
$outputBase = [IO.Path]::GetFullPath($TestOutputRoot)
$runRoot = [IO.Path]::GetFullPath((Join-Path $outputBase ('run-' + [Guid]::NewGuid().ToString('N'))))
$basePrefix = $outputBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $runRoot.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Test run directory must be a child of TestOutputRoot.'
}
$source = Join-Path $runRoot 'synthetic-codex'
$output = Join-Path $runRoot 'generated'
$sessions = Join-Path $source 'sessions'
$archives = Join-Path $source 'archived_sessions'
New-Item -ItemType Directory -Path $sessions, $archives, $output -Force | Out-Null
$checks = 0
$scenarios = 0
function Check([string]$Name, $Actual, $Expected) {
  $equal = if ($null -eq $Expected) { $null -eq $Actual } else { $Actual -eq $Expected }
  if (-not $equal) { throw "$Name expected [$Expected], got [$Actual]" }
  $script:checks++
}
function Event([string]$At, [string]$Type, $Payload) {
  [ordered]@{ timestamp = $At; type = $Type; payload = $Payload }
}
function Usage($InputTokens, $CachedTokens, $OutputTokens, $ReasoningTokens) {
  [ordered]@{
    input_tokens = $InputTokens; cached_input_tokens = $CachedTokens
    output_tokens = $OutputTokens; reasoning_output_tokens = $ReasoningTokens
    total_tokens = $InputTokens + $OutputTokens
  }
}
function Meta([string]$Id, [string]$Role = '') {
  $payload = [ordered]@{ id = $Id; session_id = 'private-parent-root' }
  if ($Role) {
    $payload.parent_thread_id = 'private-thread-parent'
    $payload.source = @{ subagent = @{ other = $Role } }
    if ($Role -eq 'guardian') { $payload.thread_source = 'guardian_review' }
  }
  Event '2026-10-12T15:50:00Z' 'session_meta' $payload
}
function Context([string]$At, [string]$Model, [string]$Effort, [string]$Turn = 'private-turn') {
  Event $At 'turn_context' @{ turn_id = $Turn; model = $Model; effort = $Effort }
}
function Record([string]$At, [AllowEmptyString()][string]$Response, $Last, $Cumulative, [string]$Turn = 'private-turn') {
  Event $At 'token_usage_record' ([ordered]@{
    response_id = $Response; thread_id = 'private-thread-parent'; turn_id = $Turn
    usage = $Last; thread_token_usage = $Cumulative; turn_token_usage = $Cumulative
  })
}
function Token([string]$At, $Last, $Cumulative, [string]$Turn = 'private-turn') {
  Event $At 'event_msg' ([ordered]@{
    type = 'token_count'; session_id = 'private-parent-root'; turn_id = $Turn
    info = [ordered]@{ last_token_usage = $Last; total_token_usage = $Cumulative }
  })
}
function Write-Events([string]$Path, [object[]]$Events) {
  $lines = @($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
  [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}
function Read-Json([string]$Path) {
  ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
function Write-Json([string]$Path, $Value) {
  [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
}
function Sum($Rows, [string]$Field = 'total') {
  $value = ($Rows | Measure-Object -Property $Field -Sum).Sum
  if ($null -eq $value) { return [long]0 }
  [long]$value
}

# A paired request is not supplemental, even if its cumulative vector differs.
# Re-emission of the same adjacent token_count state must still count only once.
$pairedLast = Usage 100 40 20 5
$pairedRecordTotal = Usage 1000 400 300 100
$pairedCountTotal = Usage 900 350 250 90
Write-Events (Join-Path $sessions 'paired.jsonl') @(
  (Meta 'private-thread-paired'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-paired' 'max'),
  (Record '2026-10-12T15:59:58Z' 'private-response-paired' $pairedLast $pairedRecordTotal),
  (Token '2026-10-12T15:59:59Z' $pairedLast $pairedCountTotal),
  (Token '2026-10-12T16:00:00Z' $pairedLast $pairedCountTotal)
)

# The first unpaired record is superseded; the second is at EOF. Both are real
# request consumption, on opposite sides of midnight in Asia/Shanghai.
Write-Events (Join-Path $sessions 'isolated.jsonl') @(
  (Meta 'private-thread-isolated'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-isolated' 'high'),
  (Record '2026-10-12T15:59:59Z' 'private-response-superseded' (Usage 200 50 30 6) (Usage 200 50 30 6)),
  (Record '2026-10-12T16:00:01Z' 'private-response-eof' (Usage 300 70 40 8) (Usage 500 120 70 14))
)

# Response identity has coverage in another source file with different actual
# metadata and cumulative state; only that file's token_count is consumed.
$crossLast = Usage 70 20 7 2
Write-Events (Join-Path $sessions 'cross-orphan.jsonl') @(
  (Meta 'private-thread-cross-orphan'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-cross-orphan' 'high'),
  (Record '2026-10-12T16:01:00Z' 'private-response-cross-file' $crossLast (Usage 10070 2000 1007 200))
)
Write-Events (Join-Path $archives 'cross-covered.jsonl') @(
  (Meta 'private-thread-cross-covered'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-cross-covered' 'low'),
  (Record '2026-10-12T16:01:01Z' 'private-response-cross-file' $crossLast (Usage 70 20 7 2)),
  (Token '2026-10-12T16:01:02Z' $crossLast (Usage 80 25 8 3))
)

# The same request in active and archived logs is supplemental only once.
$archivePath = Join-Path $sessions 'archive-active.jsonl'
Write-Events $archivePath @(
  (Meta 'private-thread-archive'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-archive' 'high'),
  (Record '2026-10-12T16:02:00Z' 'private-response-archive' (Usage 55 15 5 1) (Usage 500 150 50 10))
)
Copy-Item -LiteralPath $archivePath -Destination (Join-Path $archives 'archive-copy.jsonl')

# An old token_count-only copy covers a supplemental record's full state. It
# carries no response ID, so response-only deduplication would overcount it.
$stateLast = Usage 80 25 8 2
$stateTotal = Usage 1280 125 128 32
Write-Events (Join-Path $sessions 'state-record.jsonl') @(
  (Meta 'private-thread-state'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-state' 'medium'),
  (Record '2026-10-12T16:03:00Z' 'private-response-state' $stateLast $stateTotal)
)
Write-Events (Join-Path $archives 'state-count-only.jsonl') @(
  (Meta 'private-thread-state'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-state' 'medium'),
  (Token '2026-10-12T16:03:01Z' $stateLast $stateTotal)
)

# Equal consumption on different requests with advancing cumulative usage is
# two requests. A last-vector-only deduplication would drop half this amount.
Write-Events (Join-Path $sessions 'repeated-amount.jsonl') @(
  (Meta 'private-thread-repeat'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-repeat' 'low'),
  (Record '2026-10-12T16:04:00Z' 'private-response-repeat-1' (Usage 90 30 9 3) (Usage 90 30 9 3)),
  (Record '2026-10-12T16:04:01Z' 'private-response-repeat-2' (Usage 90 30 9 3) (Usage 180 60 18 6))
)

# All three payloads claim the parent thread. Actual metadata, model context,
# and guardian classification must remain independent source-thread facts.
Write-Events (Join-Path $sessions 'parent.jsonl') @(
  (Meta 'private-thread-parent'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-parent' 'max'),
  (Record '2026-10-12T16:05:00Z' 'private-response-parent' (Usage 40 10 4 1) (Usage 40 10 4 1))
)
Write-Events (Join-Path $sessions 'ordinary-child.jsonl') @(
  (Meta 'private-thread-child' 'worker'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-child' 'medium'),
  (Record '2026-10-12T16:05:01Z' 'private-response-child' (Usage 60 12 6 2) (Usage 60 12 6 2))
)
Write-Events (Join-Path $sessions 'guardian.jsonl') @(
  (Meta 'private-thread-guardian' 'guardian'),
  (Context '2026-10-12T15:50:01Z' 'codex-auto-review' 'low'),
  (Record '2026-10-12T16:05:02Z' 'private-response-guardian' (Usage 30 6 3 1) (Usage 30 6 3 1))
)

# Malformed source rows cannot become partial usage or misleading zero values.
$badText = Usage 1000 200 20 2; $badText.input_tokens = 'not-a-number'
$badNegative = Usage -10 0 20 2
$badFraction = Usage 1.5 0 20 2
$badBoolean = Usage 1000 200 20 2; $badBoolean.input_tokens = $true
$badCache = Usage 10 11 20 2
$badReasoning = Usage 10 0 20 21
Write-Events (Join-Path $sessions 'invalid-records.jsonl') @(
  (Meta 'private-thread-invalid'),
  (Context '2026-10-12T15:50:01Z' 'fixture-model-invalid' 'low'),
  (Record '2026-10-12T16:06:00Z' '' (Usage 1000 200 20 2) (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:01Z' 'private-response-bad-text' $badText (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:02Z' 'private-response-bad-null' $null (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:03Z' 'private-response-bad-negative' $badNegative (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:04Z' 'private-response-bad-fraction' $badFraction (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:05Z' 'private-response-bad-boolean' $badBoolean (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:06Z' 'private-response-bad-cache' $badCache (Usage 1000 200 20 2)),
  (Record '2026-10-12T16:06:07Z' 'private-response-bad-reasoning' $badReasoning (Usage 1000 200 20 2))
)

$sourceHashes = @(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
  @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
Check 'synthetic fixture file count' $sourceHashes.Count 13
$cache = Join-Path $output '.codex-usage-dashboard-cache'
$manifestPath = Join-Path $cache 'manifest.json'
$mutex = 'Local\CodexTokenFallback_' + [Guid]::NewGuid().ToString('N')
function Run([string]$Scenario, [int]$Reused, [int]$Reparsed) {
  Check "$Scenario fixed generator source" (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $messages = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $generatorPath -SourceRoot $source -OutputRoot $output -MutexName $mutex -AsOfDate '2026-10-13' 2>&1)
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  $messages | Out-File -LiteralPath (Join-Path $runRoot ($Scenario + '.log')) -Encoding UTF8
  if ($exitCode -ne 0) { throw ("$Scenario generator failed: " + ($messages -join [Environment]::NewLine)) }
  Check "$Scenario generator exit" $exitCode 0
  $json = [IO.File]::ReadAllText((Join-Path $output 'codex-usage-dashboard-data.json'))
  $data = ConvertFrom-Json -InputObject $json
  Check "$Scenario scope schema" $data.usageScopeSchema 1
  Check "$Scenario source file count" $data.refresh.files 13
  Check "$Scenario cache reused" $data.refresh.reused $Reused
  Check "$Scenario source reparsed" $data.refresh.reparsed $Reparsed
  Check "$Scenario cache version" (Read-Json $manifestPath).version 7
  Check "$Scenario supplemental request count" $data.refresh.supplementalTokenRequests 8
  Check "$Scenario only uncovered consumption is supplemental" $data.refresh.supplementalTokens 971
  foreach ($field in @('input', 'cached', 'fresh', 'output', 'reasoning', 'total')) {
    $expected = @{ input = 1115; cached = 308; fresh = 807; output = 141; reasoning = 34; total = 1256 }[$field]
    Check "$Scenario exact $field" (Sum $data.usage $field) $expected
  }
  Check "$Scenario task tokens include ordinary child" (Sum ($data.usage | Where-Object scope -eq 'task')) 1223
  Check "$Scenario review tokens" (Sum ($data.usage | Where-Object scope -eq 'auto_review')) 33
  Check "$Scenario Shanghai before midnight" (Sum ($data.usage | Where-Object date -eq '2026-10-12')) 350
  Check "$Scenario Shanghai after midnight" (Sum ($data.usage | Where-Object date -eq '2026-10-13')) 906
  $expectedBuckets = @(
    @{ date = '2026-10-12'; model = 'fixture-model-paired'; effort = 'max'; scope = 'task'; total = 120 },
    @{ date = '2026-10-12'; model = 'fixture-model-isolated'; effort = 'high'; scope = 'task'; total = 230 },
    @{ date = '2026-10-13'; model = 'fixture-model-isolated'; effort = 'high'; scope = 'task'; total = 340 },
    @{ date = '2026-10-13'; model = 'fixture-model-cross-covered'; effort = 'low'; scope = 'task'; total = 77 },
    @{ date = '2026-10-13'; model = 'fixture-model-archive'; effort = 'high'; scope = 'task'; total = 60 },
    @{ date = '2026-10-13'; model = 'fixture-model-state'; effort = 'medium'; scope = 'task'; total = 88 },
    @{ date = '2026-10-13'; model = 'fixture-model-repeat'; effort = 'low'; scope = 'task'; total = 198 },
    @{ date = '2026-10-13'; model = 'fixture-model-parent'; effort = 'max'; scope = 'task'; total = 44 },
    @{ date = '2026-10-13'; model = 'fixture-model-child'; effort = 'medium'; scope = 'task'; total = 66 },
    @{ date = '2026-10-13'; model = 'codex-auto-review'; effort = 'low'; scope = 'auto_review'; total = 33 }
  )
  Check "$Scenario exact usage row count" @($data.usage).Count $expectedBuckets.Count
  foreach ($expected in $expectedBuckets) {
    $rows = @($data.usage | Where-Object { $_.date -eq $expected.date -and $_.model -eq $expected.model })
    Check "$Scenario $($expected.model) $($expected.date) one bucket" $rows.Count 1
    foreach ($field in @('total', 'effort', 'scope')) {
      Check "$Scenario $($expected.model) $($expected.date) $field" $rows[0].$field $expected[$field]
    }
  }
  Check "$Scenario cross-file response has no supplemental orphan" @($data.usage | Where-Object model -eq 'fixture-model-cross-orphan').Count 0
  Check "$Scenario invalid request usage excluded" @($data.usage | Where-Object model -eq 'fixture-model-invalid').Count 0
  Check "$Scenario metadata identities remain separate" @($data.usage.session | Sort-Object -Unique).Count 9
  Check "$Scenario no invented request lifecycle" @($data.tasks).Count 0
  Check "$Scenario no invented compactions" @($data.compactions).Count 0
  Check "$Scenario numeric accounting" @($data.usage | Where-Object {
    $_.total -ne ($_.input + $_.output) -or $_.input -ne ($_.cached + $_.fresh) -or
    $_.cached -gt $_.input -or $_.reasoning -gt $_.output
  }).Count 0
  $html = [IO.File]::ReadAllText((Join-Path $output 'codex-usage-dashboard.html'))
  Check "$Scenario public data omits raw source identities" ($json -match 'private-thread-|private-response-|private-parent-|private-turn|synthetic-codex') $false
  Check "$Scenario public HTML omits raw source identities" ($html -match 'private-thread-|private-response-|private-parent-|private-turn|synthetic-codex') $false
  foreach ($entry in @((Read-Json $manifestPath).files)) {
    $recordPath = Join-Path $cache ($entry.cache + '.json')
    Check "$Scenario event cache hashes response identities" ([IO.File]::ReadAllText($recordPath) -match 'private-response-') $false
  }
  foreach ($item in $sourceHashes) {
    Check "$Scenario source unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash
  }
  $script:scenarios++
}

Run 'cold' 0 13
Run 'warm' 13 0

# v6 did not extract usage records or pair response identity. Do not reuse any
# part of it while updating the manifest version alone.
$manifest = Read-Json $manifestPath
foreach ($entry in @($manifest.files)) {
  $path = Join-Path $cache ($entry.cache + '.json')
  $record = Read-Json $path
  $record.version = 6
  $record.events = @($record.events | Where-Object k -ne 'token_usage_record')
  Write-Json $path $record
}
$manifest.version = 6
Write-Json $manifestPath $manifest
Run 'v6-rebuild' 0 13

function Usage-CachePath {
  foreach ($entry in @((Read-Json $manifestPath).files)) {
    $path = Join-Path $cache ($entry.cache + '.json')
    $record = Read-Json $path
    if (@($record.events | Where-Object k -eq 'token_usage_record').Count) { return $path }
  }
  throw 'No request usage event found in the v7 synthetic cache.'
}
# A matching source signature cannot bless a structurally damaged usage cache.
$recordPath = Usage-CachePath
$record = Read-Json $recordPath
$firstUsage = $record.events | Where-Object k -eq 'token_usage_record' | Select-Object -First 1
$firstUsage.l = @(1, 2)
Write-Json $recordPath $record
Run 'corrupt-usage-rebuild' 12 1

$recordPath = Usage-CachePath
$record = Read-Json $recordPath
$firstUsage = $record.events | Where-Object k -eq 'token_usage_record' | Select-Object -First 1
$firstUsage.r = 'not-a-response-hash'
Write-Json $recordPath $record
Run 'corrupt-response-rebuild' 12 1

# Response linkage is not implied by equal consumption. These separate source
# roots preserve the thirteen-file baseline while exercising source-order and
# cumulative-reset boundaries through the real generator, cold and warm.
$boundaryCaseCount = 0
function Run-Boundary([string]$Name, [object[]]$Events, [long]$ExpectedTotal,
  [long]$ExpectedInput, [long]$ExpectedCached, [long]$ExpectedOutput,
  [long]$ExpectedReasoning, [object[]]$ExpectedModels,
  [int]$ExpectedTasks = 0, [int]$ExpectedCompactions = 0) {
  # Keep cache tmp paths below Windows PowerShell 5.1's legacy path limit.
  $script:boundaryCaseCount++
  $caseRoot = Join-Path (Join-Path $runRoot 'b') ([string]$script:boundaryCaseCount)
  $caseSource = Join-Path $caseRoot 'synthetic-codex'
  $caseOutput = Join-Path $caseRoot 'generated'
  $caseSessions = Join-Path $caseSource 'sessions'
  New-Item -ItemType Directory -Path $caseSessions, $caseOutput -Force | Out-Null
  $casePath = Join-Path $caseSessions 'boundary.jsonl'
  Write-Events $casePath $Events
  $caseHash = (Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash
  foreach ($mode in @('cold', 'warm')) {
    $scenario = $Name + '-' + $mode
    Check "$scenario fixed generator source" (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $messages = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $generatorPath -SourceRoot $caseSource -OutputRoot $caseOutput -MutexName $mutex -AsOfDate '2026-10-13' 2>&1)
      $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $messages | Out-File -LiteralPath (Join-Path $caseRoot ($mode + '.log')) -Encoding UTF8
    if ($exitCode -ne 0) { throw ("$scenario generator failed: " + ($messages -join [Environment]::NewLine)) }
    Check "$scenario generator exit" $exitCode 0
    $json = [IO.File]::ReadAllText((Join-Path $caseOutput 'codex-usage-dashboard-data.json'))
    $data = ConvertFrom-Json -InputObject $json
    Check "$scenario single source file" $data.refresh.files 1
    Check "$scenario cache reuse" $data.refresh.reused $(if ($mode -eq 'cold') { 0 } else { 1 })
    Check "$scenario cache reparsed" $data.refresh.reparsed $(if ($mode -eq 'cold') { 1 } else { 0 })
    Check "$scenario scope schema" $data.usageScopeSchema 1
    Check "$scenario exactly one uncovered response" $data.refresh.supplementalTokenRequests 1
    Check "$scenario uncovered request consumes 110" $data.refresh.supplementalTokens 110
    Check "$scenario exact total" (Sum $data.usage) $ExpectedTotal
    Check "$scenario exact input" (Sum $data.usage 'input') $ExpectedInput
    Check "$scenario exact cached" (Sum $data.usage 'cached') $ExpectedCached
    Check "$scenario exact output" (Sum $data.usage 'output') $ExpectedOutput
    Check "$scenario exact reasoning" (Sum $data.usage 'reasoning') $ExpectedReasoning
    Check "$scenario exact fresh" (Sum $data.usage 'fresh') ($ExpectedInput - $ExpectedCached)
    Check "$scenario all attribution remains task scope" @($data.usage | Where-Object scope -ne 'task').Count 0
    Check "$scenario Shanghai date" @($data.usage | Where-Object date -ne '2026-10-13').Count 0
    Check "$scenario one actual usage thread" @($data.usage.session | Sort-Object -Unique).Count 1
    Check "$scenario request lifecycle count" @($data.tasks).Count $ExpectedTasks
    Check "$scenario compaction count" @($data.compactions).Count $ExpectedCompactions
    Check "$scenario model bucket count" @($data.usage).Count $ExpectedModels.Count
    foreach ($expected in $ExpectedModels) {
      $rows = @($data.usage | Where-Object model -eq $expected.model)
      Check "$scenario $($expected.model) bucket count" $rows.Count 1
      Check "$scenario $($expected.model) consumption" $rows[0].total $expected.total
      Check "$scenario $($expected.model) effort" $rows[0].effort $expected.effort
    }
    Check "$scenario no identities leaked" ($json -match 'private-thread-|private-response-|private-parent-|private-turn|synthetic-codex') $false
    Check "$scenario source unchanged" (Get-FileHash -LiteralPath $casePath -Algorithm SHA256).Hash $caseHash
    $script:scenarios++
  }
}
$boundaryLast = Usage 100 30 10 3
$boundaryDouble = Usage 200 60 20 6
$boundaryZero = Usage 0 0 0 0

# A closes without token_count. B is a new task with equal per-request usage;
# B's token_count cannot cover the earlier response in the completed task.
Run-Boundary 'completed-turn-boundary' @(
  (Meta 'private-thread-completed-boundary'),
  (Context '2026-10-13T00:00:00Z' 'fixture-boundary-a' 'high' 'private-turn-a'),
  (Event '2026-10-13T00:00:01Z' 'event_msg' @{ type = 'task_started'; turn_id = 'private-turn-a' }),
  (Record '2026-10-13T00:00:02Z' 'private-response-boundary-a' $boundaryLast $boundaryLast 'private-turn-a'),
  (Event '2026-10-13T00:00:03Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'private-turn-a'; duration_ms = 2000 }),
  (Context '2026-10-13T00:00:04Z' 'fixture-boundary-b' 'low' 'private-turn-b'),
  (Event '2026-10-13T00:00:05Z' 'event_msg' @{ type = 'task_started'; turn_id = 'private-turn-b' }),
  (Token '2026-10-13T00:00:06Z' $boundaryLast $boundaryDouble 'private-turn-b')
) 220 200 60 20 6 @(
  @{ model = 'fixture-boundary-a'; effort = 'high'; total = 110 },
  @{ model = 'fixture-boundary-b'; effort = 'low'; total = 110 }
) 2 0

# A is already matched. Compaction resets the counter and B reaches the same
# old complete state, but a distinct EOF response still consumes another 110.
Run-Boundary 'matched-response-after-reset' @(
  (Meta 'private-thread-matched-reset'),
  (Context '2026-10-13T00:00:00Z' 'fixture-boundary-reset' 'high'),
  (Record '2026-10-13T00:00:01Z' 'private-response-reset-a' $boundaryLast $boundaryLast),
  (Token '2026-10-13T00:00:02Z' $boundaryLast $boundaryLast),
  (Event '2026-10-13T00:00:03Z' 'event_msg' @{ type = 'compacted'; window_id = 'private-reset-window' }),
  (Token '2026-10-13T00:00:04Z' $boundaryZero $boundaryZero),
  (Record '2026-10-13T00:00:05Z' 'private-response-reset-b' $boundaryLast $boundaryLast)
) 220 200 60 20 6 @(
  @{ model = 'fixture-boundary-reset'; effort = 'high'; total = 220 }
) 0 1

# A turn_context change alone is a turn boundary, even without task signals.
# Equal full state in another known turn is not legacy coverage for A.
Run-Boundary 'context-only-turn-boundary' @(
  (Meta 'private-thread-context-boundary'),
  (Context '2026-10-13T00:00:00Z' 'fixture-context-a' 'high' 'private-turn-a'),
  (Record '2026-10-13T00:00:01Z' 'private-response-context-a' $boundaryLast $boundaryLast 'private-turn-a'),
  (Context '2026-10-13T00:00:02Z' 'fixture-context-b' 'low' 'private-turn-b'),
  (Token '2026-10-13T00:00:03Z' $boundaryLast $boundaryLast 'private-turn-b')
) 220 200 60 20 6 @(
  @{ model = 'fixture-context-a'; effort = 'high'; total = 110 },
  @{ model = 'fixture-context-b'; effort = 'low'; total = 110 }
)

# Another positive consumption closes the pending response candidate. A later
# request can legitimately consume the same amount as A, without covering A.
Run-Boundary 'different-positive-consumption' @(
  (Meta 'private-thread-positive-boundary'),
  (Context '2026-10-13T00:00:00Z' 'fixture-boundary-positive' 'high'),
  (Record '2026-10-13T00:00:01Z' 'private-response-positive-a' $boundaryLast $boundaryLast),
  (Token '2026-10-13T00:00:02Z' (Usage 80 20 8 2) (Usage 180 50 18 5)),
  (Token '2026-10-13T00:00:03Z' $boundaryLast (Usage 280 80 28 8))
) 308 280 80 28 8 @(
  @{ model = 'fixture-boundary-positive'; effort = 'high'; total = 308 }
)

# An anonymous legacy token_count from before the reset is not a later record's
# consumption event. This isolates the time gate without matched response IDs.
Run-Boundary 'anonymous-legacy-before-reset' @(
  (Meta 'private-thread-legacy-reset'),
  (Context '2026-10-13T00:00:00Z' 'fixture-boundary-legacy' 'high'),
  (Token '2026-10-13T00:00:01Z' $boundaryLast $boundaryLast),
  (Event '2026-10-13T00:00:02Z' 'event_msg' @{ type = 'compacted'; window_id = 'private-legacy-window' }),
  (Token '2026-10-13T00:00:03Z' $boundaryZero $boundaryZero),
  (Record '2026-10-13T00:00:04Z' 'private-response-legacy-new' $boundaryLast $boundaryLast)
) 220 200 60 20 6 @(
  @{ model = 'fixture-boundary-legacy'; effort = 'high'; total = 220 }
) 0 1

Check 'generator unchanged at completion' (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
$result = [pscustomobject]@{
  passed = $true; assertions = $checks; scenarios = $scenarios
  engine = $PSVersionTable.PSVersion.ToString(); generatorSha256 = $generatorHash
  syntheticTotal = 1256; sourceFiles = 13; boundarySourceFiles = $boundaryCaseCount; runRoot = $runRoot
}
Write-Json (Join-Path $runRoot 'result.json') $result
$result | ConvertTo-Json -Compress
