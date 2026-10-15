# Synthetic regressions for durable history and explicitly trusted cache recovery.
# Runs only against private fixtures below TestOutputRoot; never reads real logs.
[CmdletBinding()]
param(
  [string]$Generator = '',
  [string]$ExpectedGeneratorSha256 = '',
  [string]$TestOutputRoot = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
if (-not $TestOutputRoot) { $TestOutputRoot = Join-Path $PSScriptRoot 'service-fixtures\history-retention' }
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
$generatorHash = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedGeneratorSha256 -and $generatorHash -ne $ExpectedGeneratorSha256) {
  throw 'Generator SHA256 differs from the explicitly pinned test source.'
}
$engine = (Get-Process -Id $PID).Path
$outputBase = [IO.Path]::GetFullPath($TestOutputRoot)
# Compact fixture paths keep the new two-level history hashes usable on PS 5.1.
do { $runRoot = [IO.Path]::GetFullPath((Join-Path $outputBase ('r' + [Guid]::NewGuid().ToString('N').Substring(0, 4)))) }
while (Test-Path -LiteralPath $runRoot)
$basePrefix = $outputBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $runRoot.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Test run directory must be a child of TestOutputRoot.'
}
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$checks = 0
$scenarios = [Collections.Generic.List[object]]::new()
$mutex = 'Local\CodexHistoryRetention_' + [Guid]::NewGuid().ToString('N')
$failure = $null

function Check([string]$Name, $Actual, $Expected) {
  $equal = if ($null -eq $Expected) { $null -eq $Actual } else { $Actual -eq $Expected }
  if (-not $equal) { throw "$Name expected [$Expected], got [$Actual]" }
  $script:checks++
}
function Assert-TestPath([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  $prefix = $script:runRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture mutation attempted outside the verified test run directory.'
  }
  $resolved
}
function Remove-TestPath([string]$Path) {
  $resolved = Assert-TestPath $Path
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
function Move-TestFile([string]$Source, [string]$Destination) {
  $from = Assert-TestPath $Source
  $to = Assert-TestPath $Destination
  Move-Item -LiteralPath $from -Destination $to
}
function New-Case([string]$Name) {
  $root = Join-Path $script:runRoot $Name
  $source = Join-Path $root 's'
  $output = Join-Path $root 'o'
  $sessions = Join-Path $source 'sessions'
  $archives = Join-Path $source 'archived_sessions'
  New-Item -ItemType Directory -Path $sessions, $archives, $output -Force | Out-Null
  [pscustomobject]@{ root = $root; source = $source; output = $output; sessions = $sessions; archives = $archives }
}
function Event([string]$At, [string]$Type, $Payload) {
  [ordered]@{ timestamp = $At; type = $Type; payload = $Payload }
}
function Usage([long]$InputTokens, [long]$CachedTokens, [long]$OutputTokens, [long]$ReasoningTokens) {
  [ordered]@{
    input_tokens = $InputTokens; cached_input_tokens = $CachedTokens
    output_tokens = $OutputTokens; reasoning_output_tokens = $ReasoningTokens
    total_tokens = $InputTokens + $OutputTokens
  }
}
function Meta([string]$Id) {
  Event '2026-08-01T00:00:00Z' 'session_meta' @{
    id = $Id; session_id = 'private-history-parent'; cwd = 'C:\private-history-source'
  }
}
function Context([string]$At, [string]$Model = 'fixture-history-model', [string]$Turn = 'private-history-turn') {
  Event $At 'turn_context' @{ turn_id = $Turn; model = $Model; effort = 'high' }
}
function Token([string]$At, $Last, $Cumulative, [string]$Turn = 'private-history-turn') {
  Event $At 'event_msg' @{
    type = 'token_count'; turn_id = $Turn
    info = @{ last_token_usage = $Last; total_token_usage = $Cumulative }
  }
}
function Record([string]$At, [string]$Response, $Last, $Cumulative, [string]$Turn = 'private-history-turn') {
  Event $At 'token_usage_record' @{
    response_id = $Response; thread_id = 'private-history-parent'; turn_id = $Turn
    usage = $Last; thread_token_usage = $Cumulative; turn_token_usage = $Cumulative
  }
}
function Write-Events([string]$Path, [object[]]$Events) {
  $verified = Assert-TestPath $Path
  $lines = @($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
  [IO.File]::WriteAllLines($verified, $lines, [Text.UTF8Encoding]::new($false))
}
function Read-Json([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Text-Hash([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')).ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Write-Json([string]$Path, $Value) {
  $verified = Assert-TestPath $Path
  [IO.File]::WriteAllText($verified, (ConvertTo-Json -InputObject $Value -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
}
function Basic-Events([string]$Id = 'private-history-thread') {
  @(
    (Meta $Id),
    (Context '2026-08-01T00:00:01Z'),
    (Event '2026-08-01T00:00:02Z' 'response_item' @{
      type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = 'PRIVATE_HISTORY_BODY_SENTINEL' })
    }),
    (Token '2026-08-01T00:00:03Z' (Usage 0 0 0 0) (Usage 0 0 0 0)),
    (Token '2026-08-08T15:59:59Z' (Usage 100 30 10 3) (Usage 100 30 10 3)),
    (Token '2026-08-08T16:00:01Z' (Usage 50 10 5 1) (Usage 150 40 15 4))
  )
}
function Sum($Rows, [string]$Field = 'total') {
  $value = ($Rows | Measure-Object -Property $Field -Sum).Sum
  if ($null -eq $value) { return [long]0 }
  [long]$value
}
function History-Namespaces([string]$Output) {
  $root = Join-Path $Output '.codex-usage-dashboard-history'
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') }
  }
}
function History-Chunks([string]$Output) {
  foreach ($namespace in @(History-Namespaces $Output)) {
    Get-ChildItem -LiteralPath $namespace.FullName -Recurse -File -Filter '*.json' | Where-Object Name -ne 'manifest.json'
  }
}
function Check-HistoryPrivacy([string]$Output) {
  foreach ($namespace in @(History-Namespaces $Output)) {
    Check 'history namespace is a source hash' ($namespace.Name -match '^[a-f0-9]{64}$') $true
    foreach ($file in @(Get-ChildItem -LiteralPath $namespace.FullName -Recurse -File -Filter '*.json')) {
      $text = [IO.File]::ReadAllText($file.FullName)
      Check 'history does not retain conversation content or raw responses' ($text -match 'PRIVATE_HISTORY_BODY_SENTINEL|private-history-response-') $false
      Check 'history does not retain absolute local paths' ($text -match '(?i)[a-z]:[\\/]') $false
    }
  }
}
function Change-HistoryParser([string]$Output) {
  $changed = 0
  foreach ($namespace in @(History-Namespaces $Output)) {
    $manifestPath = Join-Path $namespace.FullName 'manifest.json'
    $manifest = Read-Json $manifestPath
    foreach ($entry in @($manifest.files)) {
      $chunkPath = Join-Path $namespace.FullName ($entry.hash + '.json')
      $value = Read-Json $chunkPath
      $value.parser = 'f' * 64
      # Keep integrity valid so this checks parser rejection independently.
      $json = ConvertTo-Json -InputObject $value -Depth 12 -Compress
      $contentHash = Text-Hash $json
      $changedPath = Assert-TestPath (Join-Path $namespace.FullName ($contentHash + '.json'))
      [IO.File]::WriteAllText($changedPath, $json, [Text.UTF8Encoding]::new($false))
      $entry.parser = $value.parser
      $entry.hash = $contentHash
      $changed++
    }
    Write-Json $manifestPath $manifest
  }
  Check 'history exposes at least one parser fingerprint to corrupt' ($changed -gt 0) $true
}
function Run([string]$Name, [string]$Source, [string]$Output, [long]$Total = 0,
  [int]$Retained = -1, [int]$Recovered = 0, [int]$Skipped = 0,
  [AllowNull()][string]$Start = $null, [switch]$Recover, [switch]$ExpectFailure) {
  Check "$Name fixed generator source" (Get-FileHash -LiteralPath $script:generatorPath -Algorithm SHA256).Hash $script:generatorHash
  $sourceHashes = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Filter '*.jsonl' | ForEach-Object {
    @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  })
  $dataPath = Join-Path $Output 'codex-usage-dashboard-data.json'
  $htmlPath = Join-Path $Output 'codex-usage-dashboard.html'
  $before = @{}
  if ($ExpectFailure) {
    foreach ($path in @($dataPath, $htmlPath)) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
  }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:generatorPath,
    '-SourceRoot', $Source, '-OutputRoot', $Output, '-MutexName', $script:mutex, '-AsOfDate', '2026-10-15')
  if ($Recover) { $arguments += '-RecoverHistoricalCaches' }
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $messages = @(& $script:engine @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  $messages | Out-File -LiteralPath (Join-Path $script:runRoot ($Name + '.log')) -Encoding UTF8
  foreach ($item in $sourceHashes) {
    Check "$Name source file still exists" (Test-Path -LiteralPath $item.path) $true
    Check "$Name source file unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash
  }
  if ($ExpectFailure) {
    Check "$Name rejects incomplete or incompatible committed history" ($exitCode -ne 0) $true
    foreach ($path in @($dataPath, $htmlPath)) {
      Check "$Name previous published artifact is unchanged" (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash $before[$path]
    }
    $script:scenarios.Add([ordered]@{ name = $Name; expectedFailure = $true; passed = $true; exit = $exitCode })
    return
  }
  if ($exitCode -ne 0) { throw ("$Name generator failed: " + ($messages -join [Environment]::NewLine)) }
  Check "$Name generator exit" $exitCode 0
  $data = Read-Json $dataPath
  Check "$Name exact total" (Sum $data.usage) $Total
  Check "$Name history schema" $data.refresh.history.schema 1
  foreach ($field in @('retainedFiles', 'recoveredFiles', 'skippedCaches')) {
    $number = $data.refresh.history.$field
    Check "$Name history $field is a nonnegative integer" ($number -is [ValueType] -and $number -isnot [bool] -and [double]$number -ge 0 -and [Math]::Floor([double]$number) -eq [double]$number) $true
  }
  if ($Retained -ge 0) { Check "$Name retained file count" $data.refresh.history.retainedFiles $Retained }
  Check "$Name newly recovered cache count" $data.refresh.history.recoveredFiles $Recovered
  Check "$Name skipped incompatible cache count" $data.refresh.history.skippedCaches $Skipped
  if ($Start) { Check "$Name earliest positive Shanghai day" $data.refresh.history.startDate $Start }
  else { Check "$Name no invented historical day" $data.refresh.history.startDate $null }
  Check "$Name exact token composition" @($data.usage | Where-Object {
    $_.total -ne ($_.input + $_.output) -or $_.input -ne ($_.cached + $_.fresh) -or
    $_.cached -gt $_.input -or $_.reasoning -gt $_.output
  }).Count 0
  $json = [IO.File]::ReadAllText($dataPath)
  Check "$Name output omits private fixture data" ($json -match 'PRIVATE_HISTORY_BODY_SENTINEL|private-history-thread|private-history-response-|private-history-parent|private-history-turn|(?i)[a-z]:[\\/]') $false
  Check-HistoryPrivacy $Output
  $script:scenarios.Add([ordered]@{ name = $Name; expectedFailure = $false; passed = $true; total = $Total })
  $data
}

try {
  # A normal refresh preserves extracted history independently of disposable cache.
  $a = New-Case '1'
  $aPath = Join-Path $a.sessions 'h.jsonl'
  Write-Events $aPath (Basic-Events)
  $null = Run '01-cold' $a.source $a.output 165 -Retained 0
  Check 'cold creates one source namespace' @(History-Namespaces $a.output).Count 1
  Check 'cold creates one committed source chunk' @(History-Chunks $a.output).Count 1
  $null = Run '02-warm' $a.source $a.output 165 -Retained 0
  $aParked = Join-Path $a.root 'u'
  Move-TestFile $aPath $aParked
  $data = Run '03-source-absent' $a.source $a.output 165 -Retained 1 -Start '2026-08-08'
  Check 'absent source is not counted as a current JSONL' $data.refresh.files 0
  Check 'retained records preserve the pre-midnight day' (Sum ($data.usage | Where-Object date -eq '2026-08-08')) 110
  Check 'retained records preserve the post-midnight day' (Sum ($data.usage | Where-Object date -eq '2026-08-09')) 55
  Remove-TestPath (Join-Path $a.output '.codex-usage-dashboard-cache')
  $null = Run '04-cache-disposable' $a.source $a.output 165 -Retained 1 -Start '2026-08-08'
  Move-TestFile $aParked $aPath
  $null = Run '05-source-restored' $a.source $a.output 165 -Retained 0
  $archivePath = Join-Path $a.archives 'm.jsonl'
  Move-TestFile $aPath $archivePath
  $null = Run '06-source-archived' $a.source $a.output 165 -Start '2026-08-08'
  Copy-Item -LiteralPath $archivePath -Destination $aPath
  $null = Run '07-live-archive-overlap' $a.source $a.output 165 -Retained 0

  # Reusing OutputRoot with another SourceRoot must not import the first history.
  $otherSource = Join-Path $a.root 'b'
  $otherSessions = Join-Path $otherSource 'sessions'
  New-Item -ItemType Directory -Path $otherSessions -Force | Out-Null
  $null = Run '08-source-switched-empty' $otherSource $a.output 0 -Retained 0
  Write-Events (Join-Path $otherSessions 'b.jsonl') @(
    (Meta 'private-history-other-thread'),
    (Context '2026-09-20T00:00:00Z' 'fixture-other-model'),
    (Token '2026-09-20T00:00:01Z' (Usage 30 3 3 1) (Usage 30 3 3 1))
  )
  $null = Run '09-source-switched-data' $otherSource $a.output 33 -Retained 0
  Check 'two independent canonical source namespaces exist' @(History-Namespaces $a.output).Count 2
  $null = Run '10-source-switched-back' $a.source $a.output 165 -Retained 0
  $canonicalAlias = $a.source + '\.'
  $null = Run '11-canonical-source-alias' $canonicalAlias $a.output 165 -Retained 0
  Check 'canonical source alias does not create another namespace' @(History-Namespaces $a.output).Count 2

  # Legacy orphan caches are trusted only through the explicit recovery switch.
  $b = New-Case '2'
  $bPath = Join-Path $b.sessions 'h.jsonl'
  Write-Events $bPath (Basic-Events 'private-history-import-thread')
  $seedOutput = Join-Path $b.root 'p'
  New-Item -ItemType Directory -Path $seedOutput -Force | Out-Null
  $null = Run '12-legacy-cache-seed' $b.source $seedOutput 165 -Retained 0
  $seedRecords = @(Get-ChildItem -LiteralPath (Join-Path $seedOutput '.codex-usage-dashboard-cache') -File -Filter '*.json' | Where-Object { $_.BaseName -match '^[a-f0-9]{64}$' })
  Check 'seed contains exactly one extracted v7 cache' $seedRecords.Count 1
  $legacyCache = Join-Path $b.output '.codex-usage-dashboard-cache'
  New-Item -ItemType Directory -Path $legacyCache -Force | Out-Null
  $legacyRecord = Read-Json $seedRecords[0].FullName
  $legacyRecord.PSObject.Properties.Remove('source')
  Write-Json (Join-Path $legacyCache $seedRecords[0].Name) $legacyRecord
  Move-TestFile $bPath (Join-Path $b.root 'u')
  $null = Run '13-default-no-cache-import' $b.source $b.output 0 -Retained 0
  Remove-TestPath (Join-Path $legacyCache 'manifest.json')
  $oldRecord = Read-Json $seedRecords[0].FullName
  $oldRecord.version = 6
  Write-Json (Join-Path $legacyCache (('a' * 64) + '.json')) $oldRecord
  $unknownRecord = Read-Json $seedRecords[0].FullName
  $unknownRecord.parser = 'e' * 64
  Write-Json (Join-Path $legacyCache (('b' * 64) + '.json')) $unknownRecord
  [IO.File]::WriteAllText((Assert-TestPath (Join-Path $legacyCache (('c' * 64) + '.json'))), '{broken-cache', [Text.UTF8Encoding]::new($false))
  $badModel = Read-Json $seedRecords[0].FullName
  $badModel.events[-1].mo = 42
  Write-Json (Join-Path $legacyCache (('d' * 64) + '.json')) $badModel
  $badEffort = Read-Json $seedRecords[0].FullName
  $badEffort.events[-1].ef = ' '
  Write-Json (Join-Path $legacyCache (('e' * 64) + '.json')) $badEffort
  $badSession = Read-Json $seedRecords[0].FullName
  $badSession.events[-1].s = 42
  Write-Json (Join-Path $legacyCache (('f' * 64) + '.json')) $badSession
  Check 'explicit import starts without a legacy manifest' (Test-Path -LiteralPath (Join-Path $legacyCache 'manifest.json')) $false
  $null = Run '14-explicit-orphan-import' $b.source $b.output 165 -Retained 1 -Recovered 1 -Skipped 6 -Start '2026-08-08' -Recover
  $null = Run '15-import-survives-normal-refresh' $b.source $b.output 165 -Retained 1 -Start '2026-08-08'
  $null = Run '16-repeated-import-no-duplication' $b.source $b.output 165 -Retained 1 -Skipped 6 -Start '2026-08-08' -Recover
  Move-TestFile (Join-Path $b.root 'u') $bPath
  $null = Run '17-import-source-restored' $b.source $b.output 165 -Retained 0

  # Corrupt or missing committed history cannot silently truncate a snapshot.
  $c = New-Case '3'
  $cPath = Join-Path $c.sessions 'h.jsonl'
  Write-Events $cPath (Basic-Events 'private-history-corrupt-thread')
  $null = Run '18-corruption-baseline' $c.source $c.output 165 -Retained 0
  $cChunks = @(History-Chunks $c.output)
  Check 'corruption fixture has one history chunk' $cChunks.Count 1
  Move-TestFile $cPath (Join-Path $c.root 'u')
  [IO.File]::WriteAllText((Assert-TestPath $cChunks[0].FullName), '{broken-history', [Text.UTF8Encoding]::new($false))
  $null = Run '19-corrupt-history-rejected' $c.source $c.output -ExpectFailure
  Move-TestFile (Join-Path $c.root 'u') $cPath
  $null = Run '20-corrupt-history-source-rebuild' $c.source $c.output 165 -Retained 0
  $repairedChunk = Read-Json $cChunks[0].FullName
  Check 'present source repairs the corrupted committed chunk' $repairedChunk.schema 1
  Move-TestFile $cPath (Join-Path $c.root 'u')
  $cChunks = @(History-Chunks $c.output)
  Remove-TestPath $cChunks[0].FullName
  $null = Run '21-missing-history-rejected' $c.source $c.output -ExpectFailure
  Move-TestFile (Join-Path $c.root 'u') $cPath
  $null = Run '22-missing-history-source-rebuild' $c.source $c.output 165 -Retained 0

  # Unknown parser provenance requires source logs; cached values cannot bless it.
  $d = New-Case '4'
  $dPath = Join-Path $d.sessions 'h.jsonl'
  Write-Events $dPath (Basic-Events 'private-history-parser-thread')
  $null = Run '23-parser-baseline' $d.source $d.output 165 -Retained 0
  Change-HistoryParser $d.output
  Move-TestFile $dPath (Join-Path $d.root 'u')
  $null = Run '24-unknown-history-parser-rejected' $d.source $d.output -ExpectFailure
  Move-TestFile (Join-Path $d.root 'u') $dPath
  $null = Run '25-unknown-history-parser-source-rebuild' $d.source $d.output 165 -Retained 0

  # The currently present file is authoritative over its own older saved chunk.
  $e = New-Case '5'
  $ePath = Join-Path $e.sessions 'h.jsonl'
  Write-Events $ePath (Basic-Events 'private-history-replaced-thread')
  $null = Run '26-current-source-baseline' $e.source $e.output 165 -Retained 0
  Write-Events $ePath @(
    (Meta 'private-history-replaced-thread'),
    (Context '2026-08-08T00:00:00Z'),
    (Token '2026-08-08T00:00:01Z' (Usage 60 12 6 2) (Usage 60 12 6 2))
  )
  $null = Run '27-current-source-replaces-old-chunk' $e.source $e.output 66 -Retained 0
  Move-TestFile $ePath (Join-Path $e.root 'u')
  $null = Run '28-latest-source-version-retained' $e.source $e.output 66 -Retained 1 -Start '2026-08-08'

  # A response in history is covered by its live consumption event. A distinct
  # response with equal usage after a cumulative reset still consumes tokens.
  $f = New-Case '6'
  $fPath = Join-Path $f.sessions 'h.jsonl'
  $amount = Usage 100 30 10 3
  Write-Events $fPath @(
    (Meta 'private-history-overlap-thread'),
    (Context '2026-10-13T00:00:00Z'),
    (Record '2026-10-13T00:00:01Z' 'private-history-response-shared' $amount $amount)
  )
  $data = Run '29-response-history-baseline' $f.source $f.output 110 -Retained 0
  Check 'initial request-only record is supplemental' $data.refresh.supplementalTokenRequests 1
  Move-TestFile $fPath (Join-Path $f.root 'u')
  $livePath = Join-Path $f.sessions 'l.jsonl'
  Write-Events $livePath @(
    (Meta 'private-history-overlap-thread'),
    (Context '2026-10-13T00:00:00Z'),
    (Record '2026-10-13T00:00:01Z' 'private-history-response-shared' $amount $amount),
    (Token '2026-10-13T00:00:02Z' $amount $amount),
    (Event '2026-10-13T00:00:03Z' 'event_msg' @{ type = 'compacted'; window_id = 'private-history-reset' }),
    (Token '2026-10-13T00:00:04Z' (Usage 0 0 0 0) (Usage 0 0 0 0)),
    (Record '2026-10-13T00:00:05Z' 'private-history-response-distinct' $amount $amount)
  )
  $data = Run '30-cross-history-response-and-reset' $f.source $f.output 220 -Retained 1 -Start '2026-10-13'
  Check 'only the distinct equal-amount response is supplemental' $data.refresh.supplementalTokenRequests 1
  Check 'only the distinct response contributes supplemental tokens' $data.refresh.supplementalTokens 110
  $null = Run '31-cross-history-response-warm' $f.source $f.output 220 -Retained 1 -Start '2026-10-13'

  # The legacy count-only history can also cover a live request with no response
  # linkage. An advancing cumulative state identifies later equal-amount usage.
  $g = New-Case '7'
  $gPath = Join-Path $g.sessions 'h.jsonl'
  Write-Events $gPath @(
    (Meta 'private-history-legacy-overlap-thread'),
    (Context '2026-10-13T00:00:00Z'),
    (Token '2026-10-13T00:00:02Z' $amount $amount)
  )
  $null = Run '32-count-history-baseline' $g.source $g.output 110 -Retained 0
  Move-TestFile $gPath (Join-Path $g.root 'u')
  $gLive = Join-Path $g.sessions 'l.jsonl'
  Write-Events $gLive @(
    (Meta 'private-history-legacy-overlap-thread'),
    (Context '2026-10-13T00:00:00Z'),
    (Record '2026-10-13T00:00:01Z' 'private-history-response-count-covered' $amount $amount),
    (Record '2026-10-13T00:00:03Z' 'private-history-response-count-distinct' $amount (Usage 200 60 20 6))
  )
  $data = Run '33-cross-history-numeric-state' $g.source $g.output 220 -Retained 1 -Start '2026-10-13'
  Check 'count-only history covers only the earlier request' $data.refresh.supplementalTokenRequests 1
  Check 'advancing equal-amount request remains supplemental' $data.refresh.supplementalTokens 110
  $null = Run '34-cross-history-numeric-state-warm' $g.source $g.output 220 -Retained 1 -Start '2026-10-13'

  # Updating A before a different missing-source B fails validation must not
  # overwrite any blob referenced by the still-committed previous manifest.
  $h = New-Case '8'
  $hAPath = Join-Path $h.sessions 'a.jsonl'
  $hBPath = Join-Path $h.sessions 'b.jsonl'
  Write-Events $hAPath (Basic-Events 'private-history-atomic-a')
  Write-Events $hBPath (Basic-Events 'private-history-atomic-b')
  $aKey = Text-Hash ((Get-Item -LiteralPath $hAPath).FullName)
  $bKey = Text-Hash ((Get-Item -LiteralPath $hBPath).FullName)
  $null = Run '35-atomic-history-baseline' $h.source $h.output 330 -Retained 0
  $hNamespace = @(History-Namespaces $h.output)[0].FullName
  $hManifestPath = Join-Path $hNamespace 'manifest.json'
  $committedManifest = [IO.File]::ReadAllText($hManifestPath)
  $hIndex = Read-Json $hManifestPath
  $aEntry = @($hIndex.files | Where-Object key -eq $aKey)[0]
  $bEntry = @($hIndex.files | Where-Object key -eq $bKey)[0]
  Check 'atomic baseline indexes the first source' ([bool]$aEntry) $true
  Check 'atomic baseline indexes the second source' ([bool]$bEntry) $true
  $oldABlob = Join-Path $hNamespace ($aEntry.hash + '.json')
  $oldBBlob = Join-Path $hNamespace ($bEntry.hash + '.json')
  $committedB = [IO.File]::ReadAllText($oldBBlob)
  Move-TestFile $hBPath (Join-Path $h.root 'v')
  [IO.File]::WriteAllText((Assert-TestPath $oldBBlob), '{broken-history', [Text.UTF8Encoding]::new($false))
  $updatedA = @(Basic-Events 'private-history-atomic-a') + @(
    (Token '2026-08-09T00:00:00Z' (Usage 70 20 7 2) (Usage 220 60 22 6))
  )
  Write-Events $hAPath $updatedA
  $null = Run '36-failed-refresh-cannot-rewrite-committed-blobs' $h.source $h.output -ExpectFailure
  Check 'failed refresh leaves the committed manifest unchanged' ([IO.File]::ReadAllText($hManifestPath)) $committedManifest
  Check 'failed refresh leaves the old A content-address blob valid' (Text-Hash ([IO.File]::ReadAllText($oldABlob))) $aEntry.hash
  Move-TestFile $hAPath (Join-Path $h.root 'u')
  [IO.File]::WriteAllText((Assert-TestPath $oldBBlob), $committedB, [Text.UTF8Encoding]::new($false))
  $null = Run '37-failed-refresh-recovers-last-committed-history' $h.source $h.output 330 -Retained 2 -Start '2026-08-08'

  # Correct JSON and content hashes cannot bless invalid structural field types.
  # Each variant must fail before publishing, while valid committed history can
  # be selected again without the source log or invented replacement data.
  $j = New-Case '9'
  $jPath = Join-Path $j.sessions 'h.jsonl'
  Write-Events $jPath (Basic-Events 'private-history-structural-thread')
  $null = Run '38-structural-history-baseline' $j.source $j.output 165 -Retained 0
  $jNamespace = @(History-Namespaces $j.output)[0].FullName
  $jManifestPath = Join-Path $jNamespace 'manifest.json'
  $jCommittedManifest = [IO.File]::ReadAllText($jManifestPath)
  $jEntry = @((Read-Json $jManifestPath).files)[0]
  $jOriginalBlob = Join-Path $jNamespace ($jEntry.hash + '.json')
  Move-TestFile $jPath (Join-Path $j.root 'u')
  foreach ($variant in @(
    @{ field = 'mo'; value = 42; scenario = '39-numeric-history-model-rejected' },
    @{ field = 'ef'; value = ' '; scenario = '40-blank-history-effort-rejected' },
    @{ field = 's'; value = 42; scenario = '41-numeric-history-session-rejected' }
  )) {
    $invalidHistory = Read-Json $jOriginalBlob
    $invalidHistory.events[-1].($variant.field) = $variant.value
    $invalidJson = ConvertTo-Json -InputObject $invalidHistory -Depth 12 -Compress
    $invalidHash = Text-Hash $invalidJson
    $invalidPath = Assert-TestPath (Join-Path $jNamespace ($invalidHash + '.json'))
    [IO.File]::WriteAllText($invalidPath, $invalidJson, [Text.UTF8Encoding]::new($false))
    $invalidIndex = ConvertFrom-Json -InputObject $jCommittedManifest
    $invalidIndex.files[0].hash = $invalidHash
    Write-Json $jManifestPath $invalidIndex
    $null = Run $variant.scenario $j.source $j.output -ExpectFailure
  }
  [IO.File]::WriteAllText((Assert-TestPath $jManifestPath), $jCommittedManifest, [Text.UTF8Encoding]::new($false))
  $null = Run '42-valid-structural-history-restored' $j.source $j.output 165 -Retained 1 -Start '2026-08-08'

  Check 'generator unchanged at completion' (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
} catch { $failure = $_ }

$result = [ordered]@{
  passed = ($null -eq $failure); assertions = $checks; scenarios = $scenarios.Count
  engine = $PSVersionTable.PSVersion.ToString(); generatorSha256 = $generatorHash
  runRoot = $runRoot; cases = @($scenarios)
}
if ($failure) { $result.failure = [string]$failure }
Write-Json (Join-Path $runRoot 'result.json') $result
$result | ConvertTo-Json -Depth 6 -Compress
if ($failure) { throw $failure }
