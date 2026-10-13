# Synthetic integration tests. Never reads the real Codex home or changes its logs.
# Run this script with both Windows PowerShell 5.1 and the preferred pwsh runtime.
[CmdletBinding()]
param(
  [string]$Generator,
  [string]$ExpectedGeneratorSha256,
  [string]$TestOutputRoot = (Join-Path ([IO.Path]::GetTempPath()) 'codex-dashboard-generator-tests')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
$generatorSha256AtStart = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedGeneratorSha256 -and $generatorSha256AtStart -ne $ExpectedGeneratorSha256) { throw 'Generator SHA256 differs from the explicitly pinned test source.' }
$enginePath = (Get-Process -Id $PID).Path
$outputBase = [IO.Path]::GetFullPath($TestOutputRoot)
$runId = 'run-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runRoot = [IO.Path]::GetFullPath((Join-Path $outputBase $runId))
$basePrefix = $outputBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $runRoot.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'The test run directory must be a child of TestOutputRoot.'
}
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$sourceRoot = Join-Path $runRoot 'synthetic-codex'
$outputRoot = Join-Path $runRoot 'generated'
New-Item -ItemType Directory -Path $sourceRoot, $outputRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\sessions') -Destination $sourceRoot -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\archived_sessions') -Destination $sourceRoot -Recurse
$assertions = [Collections.Generic.List[object]]::new()
$scenarios = [Collections.Generic.List[object]]::new()
$failure = $null
$cacheRoot = Join-Path $outputRoot '.codex-usage-dashboard-cache'
$manifestPath = Join-Path $cacheRoot 'manifest.json'
$mutexName = 'Local\CodexDashboardTest_' + [Guid]::NewGuid().ToString('N')
$metadataRunRoot = $null
$emptyMetadataRoot = $null
$originalUsername = $env:USERNAME

function Assert-Equal([string]$Name, [AllowNull()][object]$Actual, [AllowNull()][object]$Expected) {
  $passed = if ($null -eq $Expected) { $null -eq $Actual } else { $Actual -eq $Expected }
  $assertions.Add([pscustomobject]@{ name = $Name; passed = [bool]$passed; actual = $Actual; expected = $Expected })
  if (-not $passed) {
    throw ('{0}: expected [{1}], got [{2}]' -f $Name, $Expected, $Actual)
  }
}
function Write-JsonFile([string]$Path, [object]$Value) {
  $json = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
  [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
function Read-JsonFile([string]$Path) {
  ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
}
function Get-PathKey([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))).Replace('-', '')).ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Find-GeneratorFunction([string]$SourceText, [string]$Name) {
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($SourceText, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'Cannot inspect an invalid synthetic generator.' }
  $nodes = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
  if ($nodes.Count -ne 1) { throw ('Expected exactly one generator function: ' + $Name) }
  $nodes[0]
}
function Get-TestParserFingerprint([string]$SourceText) {
  # Evaluate only the generator's pure fingerprint helper, never the generator body.
  $definition = Find-GeneratorFunction $SourceText 'GetParserFingerprint'
  $entry = [ScriptBlock]::Create($definition.Extent.Text + [Environment]::NewLine + 'GetParserFingerprint $args[0]')
  & $entry $SourceText
}
$expectedParserFingerprint = Get-TestParserFingerprint ([IO.File]::ReadAllText($generatorPath))
function Assert-DashboardData([string]$Scenario, [object]$Data) {
  Assert-Equal "$Scenario schema" $Data.schema 2
  Assert-Equal "$Scenario usage rows" @($Data.usage).Count 3
  foreach ($metric in @('input', 'cached', 'fresh', 'output', 'reasoning', 'total')) {
    $expected = @{ input = 300; cached = 90; fresh = 210; output = 70; reasoning = 21; total = 370 }[$metric]
    $actual = ($Data.usage | Measure-Object -Property $metric -Sum).Sum
    Assert-Equal "$Scenario aggregate $metric" $actual $expected
  }
  foreach ($expectedDay in @(
    @{ date = '2026-09-01'; total = 240; model = 'fixture-model-a'; effort = 'high'; input = 200; cached = 70; fresh = 130; output = 40; reasoning = 11 },
    @{ date = '2026-09-06'; total = 78; model = 'fixture-model-b'; effort = 'low'; input = 60; cached = 12; fresh = 48; output = 18; reasoning = 6 },
    @{ date = '2026-09-07'; total = 52; model = 'fixture-model-b'; effort = 'low'; input = 40; cached = 8; fresh = 32; output = 12; reasoning = 4 }
  )) {
    $rows = @($Data.usage | Where-Object { $_.date -eq $expectedDay.date })
    Assert-Equal "$Scenario $($expectedDay.date) row count" $rows.Count 1
    foreach ($field in @('total', 'model', 'effort', 'input', 'cached', 'fresh', 'output', 'reasoning')) {
      Assert-Equal "$Scenario $($expectedDay.date) $field" $rows[0].$field $expectedDay[$field]
    }
  }
  Assert-Equal "$Scenario repeated state count" $Data.duplicates 1
  Assert-Equal "$Scenario compactions merged across signal types" @($Data.compactions).Count 2
  Assert-Equal "$Scenario compaction day" @($Data.compactions | Where-Object { $_.date -ne '2026-09-01' }).Count 0
  Assert-Equal "$Scenario turn count" @($Data.tasks).Count 4
  $cross = @($Data.tasks | Where-Object { $_.startedDate -eq '2026-08-31' })
  Assert-Equal "$Scenario cross-month turn count" $cross.Count 1
  Assert-Equal "$Scenario turn start recorded" $cross[0].started $true
  Assert-Equal "$Scenario turn completion recorded" $cross[0].completed $true
  Assert-Equal "$Scenario old completion-date semantics" $cross[0].date '2026-09-01'
  Assert-Equal "$Scenario milliseconds converted to seconds" $cross[0].duration 120
  Assert-Equal "$Scenario fractional first-token seconds" $cross[0].ttfb 1.25
  $missing = @($Data.tasks | Where-Object { $_.completed -and $null -eq $_.duration })
  Assert-Equal "$Scenario missing duration remains null" $missing.Count 1
  Assert-Equal "$Scenario missing first-token time remains null" $missing[0].ttfb $null
  Assert-Equal "$Scenario same-day start" $missing[0].startedDate '2026-09-01'
  $zero = @($Data.tasks | Where-Object { $_.completed -and $null -ne $_.duration -and $_.duration -eq 0 })
  Assert-Equal "$Scenario measured zero duration kept" $zero.Count 1
  Assert-Equal "$Scenario measured zero first-token time kept" $zero[0].ttfb 0
  $open = @($Data.tasks | Where-Object { $_.started -and -not $_.completed })
  Assert-Equal "$Scenario open turn count" $open.Count 1
  Assert-Equal "$Scenario open duration is unknown" $open[0].duration $null
  Assert-Equal "$Scenario open first-token time is unknown" $open[0].ttfb $null
}
function Get-ReferencedCacheBytes([string]$CacheDirectory) {
  $bytes = [int64]0
  $cacheManifest = Join-Path $CacheDirectory 'manifest.json'
  if (-not (Test-Path -LiteralPath $cacheManifest)) { return $bytes }
  try { $manifest = Read-JsonFile $cacheManifest } catch { return $bytes }
  foreach ($entry in @($manifest.files)) {
    $path = Join-Path $CacheDirectory ([string]$entry.cache + '.json')
    if (Test-Path -LiteralPath $path) { $bytes += (Get-Item -LiteralPath $path).Length }
  }
  $bytes
}
function Get-ExpectedRefreshCosts([string]$Scenario, [string]$SourceDirectory, [string]$CacheDirectory,
  [int]$ExpectedReused, [int]$ExpectedReparsed, [string[]]$ExpectedReparsedFiles, [bool]$SkipChangedSourceCacheReads) {
  $files = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Filter '*.jsonl')
  $allBytes = [int64]($files | Measure-Object -Property Length -Sum).Sum
  $readBytes = [int64]0
  if ($ExpectedReparsed -eq $files.Count) { $readBytes = $allBytes }
  elseif ($ExpectedReparsed -gt 0) {
    Assert-Equal "$Scenario expected source read list is complete" $ExpectedReparsedFiles.Count $ExpectedReparsed
    foreach ($relative in $ExpectedReparsedFiles) { $readBytes += (Get-Item -LiteralPath (Join-Path $SourceDirectory $relative)).Length }
  }
  $cacheReadBytes = if ($ExpectedReused -eq 0) { [int64]0 } else { Get-ReferencedCacheBytes $CacheDirectory }
  if ($SkipChangedSourceCacheReads) {
    foreach ($relative in $ExpectedReparsedFiles) {
      $sourcePath = (Get-Item -LiteralPath (Join-Path $SourceDirectory $relative)).FullName
      $cachePath = Join-Path $CacheDirectory ((Get-PathKey $sourcePath) + '.json')
      if (Test-Path -LiteralPath $cachePath) { $cacheReadBytes -= (Get-Item -LiteralPath $cachePath).Length }
    }
  }
  [pscustomobject]@{ sourceBytes = $allBytes; sourceBytesRead = $readBytes; cacheBytesRead = $cacheReadBytes }
}
function Assert-RefreshCosts([string]$Scenario, [object]$Data, [object]$Expected, [string]$CacheDirectory) {
  foreach ($field in @('sourceBytes', 'sourceBytesRead', 'cacheBytesRead', 'cacheBytes', 'elapsedMs')) {
    $value = $Data.refresh.$field
    Assert-Equal "$Scenario $field is nonnegative numeric" (($value -is [ValueType]) -and [double]$value -ge 0 -and -not [double]::IsNaN([double]$value) -and -not [double]::IsInfinity([double]$value)) $true
  }
  foreach ($field in @('sourceBytes', 'sourceBytesRead', 'cacheBytesRead')) {
    Assert-Equal "$Scenario exact $field" $Data.refresh.$field $Expected.$field
  }
  Assert-Equal "$Scenario exact referenced cacheBytes" $Data.refresh.cacheBytes (Get-ReferencedCacheBytes $CacheDirectory)
}
function Invoke-Generator([string]$Scenario, [int]$ExpectedReused, [int]$ExpectedReparsed,
  [string[]]$ExpectedReparsedFiles = @(), [switch]$SkipChangedSourceCacheReads) {
  Assert-Equal "$Scenario original generator hash remains fixed" (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorSha256AtStart
  $expectedCosts = Get-ExpectedRefreshCosts $Scenario $sourceRoot $cacheRoot $ExpectedReused $ExpectedReparsed $ExpectedReparsedFiles ([bool]$SkipChangedSourceCacheReads)
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $generatorPath,
    '-SourceRoot', $sourceRoot, '-OutputRoot', $outputRoot, '-MutexName', $mutexName)
  $logPath = Join-Path $runRoot ($Scenario + '.log')
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $messages = @(& $enginePath @arguments 2>&1)
    $processExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedPreference
  }
  $messages | Out-File -LiteralPath $logPath -Encoding UTF8
  $scenarios.Add([pscustomobject]@{ scenario = $Scenario; exit = $processExit; log = $logPath })
  Assert-Equal "$Scenario process exit" $processExit 0
  $data = Read-JsonFile (Join-Path $outputRoot 'codex-usage-dashboard-data.json')
  Assert-DashboardData $Scenario $data
  Assert-Equal "$Scenario empty activity schema" $data.skills.activitySchema 1
  Assert-Equal "$Scenario no Skill activity without tool reads" @($data.skills.activity).Count 0
  Assert-Equal "$Scenario empty Skill metadata schema" $data.skills.metadataSchema 1
  Assert-Equal "$Scenario no metadata without observed Skills" @($data.skills.metadata).Count 0
  Assert-Equal "$Scenario source file count" $data.refresh.files 3
  Assert-Equal "$Scenario reused files" $data.refresh.reused $ExpectedReused
  Assert-Equal "$Scenario reparsed files" $data.refresh.reparsed $ExpectedReparsed
  Assert-Equal "$Scenario no legacy parser migration" $data.refresh.migrated 0
  Assert-RefreshCosts $Scenario $data $expectedCosts $cacheRoot
  $manifest = Read-JsonFile $manifestPath
  Assert-Equal "$Scenario manifest cache version" $manifest.version 5
  Assert-Equal "$Scenario manifest parser matches source" $manifest.parser $expectedParserFingerprint
  foreach ($entry in @($manifest.files)) {
    $record = Read-JsonFile (Join-Path $cacheRoot ([string]$entry.cache + '.json'))
    Assert-Equal "$Scenario manifest key is SHA256" ([string]$entry.key -match '^[a-f0-9]{64}$') $true
    Assert-Equal "$Scenario manifest cache matches key" $entry.cache $entry.key
    Assert-Equal "$Scenario manifest omits source path" ($null -eq $entry.PSObject.Properties['path']) $true
    Assert-Equal "$Scenario cache record version $($entry.key)" $record.version 5
    Assert-Equal "$Scenario cache parser matches source $($entry.key)" $record.parser $expectedParserFingerprint
  }
  Assert-Equal "$Scenario HTML was generated" (Test-Path -LiteralPath (Join-Path $outputRoot 'codex-usage-dashboard.html')) $true
}
function Get-CacheRecordPath([string]$FixtureName, [string]$SourceDirectory = $sourceRoot, [string]$CacheDirectory = $cacheRoot) {
  $manifest = Read-JsonFile (Join-Path $CacheDirectory 'manifest.json')
  $fixtures = @(Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Filter $FixtureName)
  Assert-Equal "locate synthetic source $FixtureName" $fixtures.Count 1
  $fixtureKey = Get-PathKey $fixtures[0].FullName
  $entries = @($manifest.files | Where-Object { [string]$_.key -eq $fixtureKey })
  Assert-Equal "locate synthetic cache $FixtureName" $entries.Count 1
  $recordPath = [IO.Path]::GetFullPath((Join-Path $CacheDirectory ([string]$entries[0].cache + '.json')))
  $cachePrefix = [IO.Path]::GetFullPath($CacheDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $recordPath.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Synthetic cache mutation escaped the test cache directory.'
  }
  $recordPath
}

function Assert-SkillRow([string]$Scenario, [object]$Data, [string]$Skill, [string]$Source, [int]$Reads7, [int]$Tasks7, [int]$Reads30, [int]$Tasks30) {
  $rows = @($Data.skills.rows | Where-Object { $_.skill -eq $Skill -and $_.source -eq $Source })
  Assert-Equal "$Scenario $Source/$Skill row count" $rows.Count 1
  foreach ($expected in @(
    @{ field = 'readTurns7'; value = $Reads7 }, @{ field = 'tasks7'; value = $Tasks7 },
    @{ field = 'readTurns30'; value = $Reads30 }, @{ field = 'tasks30'; value = $Tasks30 }
  )) {
    Assert-Equal "$Scenario $Source/$Skill $($expected.field)" $rows[0].($expected.field) $expected.value
  }
}
function Assert-NoSkillRead([string]$Scenario, [object]$Data, [string]$Skill) {
  $rows = @($Data.skills.rows | Where-Object { $_.skill -eq $Skill })
  Assert-Equal "$Scenario $Skill has no in-window reads" $rows.Count 0
}
function Assert-SkillActivity([string]$Scenario, [object]$Data, [bool]$IncrementalRead, [string]$AsOfDate) {
  Assert-Equal "$Scenario activity schema" $Data.skills.activitySchema 1
  $activity = @($Data.skills.activity)
  $expectedCount = if ($AsOfDate -eq '2026-09-29') { 37 } else { 36 }
  if ($IncrementalRead) { $expectedCount++ }
  Assert-Equal "$Scenario full-history activity rows" $activity.Count $expectedCount
  foreach ($row in $activity) {
    Assert-Equal "$Scenario activity fields are anonymous" ((@($row.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'date,skill,source,task,turn') $true
    Assert-Equal "$Scenario activity date is Shanghai day" ([string]$row.date -match '^\d{4}-\d{2}-\d{2}$') $true
    Assert-Equal "$Scenario activity excludes future dates" ([string]$row.date -le $AsOfDate) $true
    foreach ($field in @('task', 'turn')) {
      Assert-Equal "$Scenario activity $field uses a positive numeric alias" (($row.$field -is [ValueType]) -and $row.$field -gt 0 -and [Math]::Floor([double]$row.$field) -eq $row.$field) $true
    }
  }
  Assert-Equal "$Scenario activity task aliases" @($activity.task | Sort-Object -Unique).Count 3
  $expectedTurns = if ($AsOfDate -eq '2026-09-29') { 12 } else { 11 }
  Assert-Equal "$Scenario activity global turn aliases" @($activity.turn | Sort-Object -Unique).Count $expectedTurns
  foreach ($group in @($activity | Group-Object turn)) {
    Assert-Equal "$Scenario turn alias belongs to exactly one task" @($group.Group.task | Sort-Object -Unique).Count 1
  }
  foreach ($group in @($activity | Group-Object date, skill, source, turn)) {
    Assert-Equal "$Scenario same-day same-Skill same-turn activity is unique" $group.Count 1
  }
  $alpha = @($activity | Where-Object { $_.skill -eq 'alpha' -and $_.source -eq 'personal' })
  Assert-Equal "$Scenario alpha activity read turns" @($alpha.turn | Sort-Object -Unique).Count 3
  Assert-Equal "$Scenario alpha activity tasks" @($alpha.task | Sort-Object -Unique).Count 2
  Assert-Equal "$Scenario same task can have two read turns" @($alpha | Where-Object { $_.date -eq '2026-09-27' }).Count 2
  $workspaceAlpha = @($activity | Where-Object { $_.skill -eq 'alpha' -and $_.source -eq 'workspace' })
  Assert-Equal "$Scenario same physical turn shares alias across Skill sources" ($workspaceAlpha[0].turn -in $alpha.turn) $true
  $historical = @($activity | Where-Object { $_.skill -eq 'before-30' })
  Assert-Equal "$Scenario activity retains history before thirty-day window" $historical.Count 1
  Assert-Equal "$Scenario historical activity date" $historical[0].date '2026-08-29'
  foreach ($skill in @('cross-seven', 'cross-thirty')) {
    $cross = @($activity | Where-Object { $_.skill -eq $skill })
    Assert-Equal "$Scenario $skill has one activity per day" $cross.Count 2
    Assert-Equal "$Scenario $skill is one turn across dates" @($cross.turn | Sort-Object -Unique).Count 1
    Assert-Equal "$Scenario $skill is one task across dates" @($cross.task | Sort-Object -Unique).Count 1
  }
  foreach ($row in @($Data.skills.rows)) {
    foreach ($days in @(7, 30)) {
      $window = $Data.skills.windows.('days' + $days)
      $selected = @($activity | Where-Object { $_.skill -eq $row.skill -and $_.source -eq $row.source -and $_.date -ge $window.start -and $_.date -le $window.end })
      Assert-Equal "$Scenario activity projects to $days-day read turns $($row.source)/$($row.skill)" @($selected | ForEach-Object { $_.turn } | Sort-Object -Unique).Count $row.('readTurns' + $days)
      Assert-Equal "$Scenario activity projects to $days-day tasks $($row.source)/$($row.skill)" @($selected | ForEach-Object { $_.task } | Sort-Object -Unique).Count $row.('tasks' + $days)
    }
  }
  $activityJson = ConvertTo-Json -InputObject $activity -Depth 4 -Compress
  Assert-Equal "$Scenario activity contains no source identities" ($activityJson -notmatch 'skill-main-a|skill-main-b|skill-time-boundaries|turn-a|turn-b|same-turn|fixture-private|synthetic-private') $true
}
function Assert-SkillData([string]$Scenario, [object]$Data, [bool]$IncrementalRead, [string]$AsOfDate) {
  Assert-Equal "$Scenario schema remains unchanged" $Data.schema 2
  Assert-Equal "$Scenario explicit proxy metric" $Data.skills.metric 'skill_instruction_reads'
  Assert-Equal "$Scenario Asia/Shanghai" $Data.skills.timeZone 'Asia/Shanghai'
  Assert-Equal "$Scenario main-session scope" $Data.skills.scope 'main_sessions'
  Assert-Equal "$Scenario deterministic as-of date" $Data.skills.asOf $AsOfDate
  $date = [DateTime]::ParseExact($AsOfDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  Assert-Equal "$Scenario seven-day start" $Data.skills.windows.days7.start $date.AddDays(-6).ToString('yyyy-MM-dd')
  Assert-Equal "$Scenario seven-day end" $Data.skills.windows.days7.end $AsOfDate
  Assert-Equal "$Scenario thirty-day start" $Data.skills.windows.days30.start $date.AddDays(-29).ToString('yyyy-MM-dd')
  Assert-Equal "$Scenario thirty-day end" $Data.skills.windows.days30.end $AsOfDate

  # Three reads of alpha in one turn and an archived copy still represent one read turn.
  # Its second turn adds a read; a second session sharing turn-a adds a second task.
  Assert-SkillRow $Scenario $Data 'alpha' 'personal' 3 2 3 2
  foreach ($skill in @('wrapped-double', 'wrapped-single', 'wrapped-template', 'shell-command', 'shell-array', 'custom-direct', 'gc-reader', 'function-wrapper',
    'head-reader', 'tail-reader', 'more-reader', 'bat-reader', 'type-reader', 'sed-reader', 'select-reader', 'rg-reader', 'after-damaged-line')) {
    Assert-SkillRow $Scenario $Data $skill 'personal' 1 1 1 1
  }
  Assert-SkillRow $Scenario $Data 'openai-docs' 'system' 1 1 1 1
  Assert-SkillRow $Scenario $Data 'documents:documents' 'plugin' 1 1 1 1
  foreach ($skill in @('local-check', 'relative-check', 'alpha')) {
    Assert-SkillRow $Scenario $Data $skill 'workspace' 1 1 1 1
  }
  $unknown = @($Data.skills.rows | Where-Object { $_.source -eq 'unknown' })
  Assert-Equal "$Scenario unknown source row" $unknown.Count 1
  Assert-Equal "$Scenario unknown skill is anonymized" ([string]$unknown[0].skill -match '^[a-z][a-z0-9-]*[0-9a-f]{8,64}$') $true
  Assert-Equal "$Scenario unknown skill does not retain directory name" ([string]$unknown[0].skill -notmatch 'private|title|workspace') $true
  Assert-SkillRow $Scenario $Data ([string]$unknown[0].skill) 'unknown' 1 1 1 1

  Assert-SkillRow $Scenario $Data 'before-7' 'personal' 0 0 1 1
  Assert-SkillRow $Scenario $Data 'end-today' 'personal' 1 1 1 1
  if ($AsOfDate -eq '2026-09-28') {
    Assert-SkillRow $Scenario $Data 'cross-seven' 'personal' 1 1 1 1
    Assert-SkillRow $Scenario $Data 'cross-thirty' 'personal' 0 0 1 1
    Assert-SkillRow $Scenario $Data 'at-30' 'personal' 0 0 1 1
    Assert-SkillRow $Scenario $Data 'at-7' 'personal' 1 1 1 1
    Assert-SkillRow $Scenario $Data 'offset-timestamp' 'personal' 1 1 1 1
    Assert-NoSkillRead $Scenario $Data 'future-day'
  } else {
    Assert-SkillRow $Scenario $Data 'cross-seven' 'personal' 0 0 1 1
    Assert-NoSkillRead $Scenario $Data 'cross-thirty'
    Assert-NoSkillRead $Scenario $Data 'at-30'
    Assert-SkillRow $Scenario $Data 'at-7' 'personal' 0 0 1 1
    Assert-SkillRow $Scenario $Data 'offset-timestamp' 'personal' 0 0 1 1
    Assert-SkillRow $Scenario $Data 'future-day' 'personal' 1 1 1 1
  }
  foreach ($skill in @('before-30', 'listed-only', 'mentioned-only', 'said-only', 'path-get-item', 'path-test',
    'path-write-output', 'path-echo', 'path-rg-files', 'path-rg-list', 'path-rg-list-long', 'path-rg-without-match', 'path-rg-combined-list', 'path-list',
    'echo-fake-reader', 'comment-fake', 'string-fake', 'function-fake', 'false-branch-fake', 'dynamic-reader',
    'tool-output-fake', 'unknown-tool', 'invalid-timestamp', 'missing-turn', 'excluded-late-metadata',
    'rg-pattern-only', 'select-pattern-only', 'help-only', 'and-unexecuted', 'after-return',
    'spread-overwrite', 'dynamic-overwrite', 'after-exit', 'regex-only',
    'excluded-04-parent', 'excluded-05-subagent', 'excluded-06-guardian', 'excluded-07-agent-path', 'excluded-08-thread-subagent')) {
    Assert-NoSkillRead $Scenario $Data $skill
  }
  if ($IncrementalRead) { Assert-SkillRow $Scenario $Data 'incremental-new' 'personal' 1 1 1 1 }
  else { Assert-NoSkillRead $Scenario $Data 'incremental-new' }
  $expectedRows = if ($AsOfDate -eq '2026-09-29') { 30 } else { 31 }
  if ($IncrementalRead) { $expectedRows++ }
  Assert-Equal "$Scenario only expected Skill rows" @($Data.skills.rows).Count $expectedRows
  # Skill scope must not change the existing Token scope, including subagents.
  foreach ($metric in @('input', 'cached', 'fresh', 'output', 'reasoning', 'total')) {
    $expected = @{ input = 21; cached = 3; fresh = 18; output = 9; reasoning = 1; total = 30 }[$metric]
    Assert-Equal "$Scenario token scope retained $metric" ($Data.usage | Measure-Object -Property $metric -Sum).Sum $expected
  }
  Assert-SkillActivity $Scenario $Data $IncrementalRead $AsOfDate
  Assert-SkillMetadataContract $Scenario $Data
}
function Assert-SkillMetadataContract([string]$Scenario, [object]$Data) {
  Assert-Equal "$Scenario metadata schema" $Data.skills.metadataSchema 1
  Assert-Equal "$Scenario metadata date is actual Shanghai refresh day" $Data.skills.metadataAsOf ([DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd'))
  $identities = @{}
  foreach ($row in @($Data.skills.activity)) { $identities[$row.source + '|' + $row.skill] = $true }
  $seen = @{}
  Assert-Equal "$Scenario one metadata row per historical observed identity" @($Data.skills.metadata).Count $identities.Count
  foreach ($row in @($Data.skills.metadata)) {
    $key = $row.source + '|' + $row.skill
    Assert-Equal "$Scenario metadata fields are safe" ((@($row.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'description,name,skill,source,status') $true
    Assert-Equal "$Scenario metadata identity was observed" $identities.ContainsKey($key) $true
    Assert-Equal "$Scenario metadata identity is unique" $seen.ContainsKey($key) $false
    $seen[$key] = $true
    Assert-Equal "$Scenario metadata status is explicit" ($row.status -in 'available', 'missing', 'ambiguous') $true
    Assert-Equal "$Scenario metadata name is text" ($row.name -is [string]) $true
    Assert-Equal "$Scenario metadata description is text" ($row.description -is [string]) $true
    if ($row.status -eq 'available') {
      Assert-Equal "$Scenario available metadata has name or description" ([bool]($row.name -or $row.description)) $true
    } else {
      Assert-Equal "$Scenario unavailable metadata hides name" $row.name ''
      Assert-Equal "$Scenario unavailable metadata hides description" $row.description ''
    }
  }
  foreach ($field in @('candidates', 'reused', 'reparsed', 'bytesRead', 'cacheBytes')) {
    $value = $Data.refresh.skillMetadata.$field
    Assert-Equal "$Scenario metadata $field is nonnegative numeric" (($value -is [ValueType]) -and [double]$value -ge 0) $true
  }
  Assert-Equal "$Scenario inventory schema" $Data.skills.inventorySchema 1
  Assert-Equal "$Scenario inventory date is actual Shanghai refresh day" $Data.skills.inventoryAsOf ([DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd'))
  Assert-Equal "$Scenario inventory scope" $Data.skills.inventoryScope 'known_local_skill_roots'
  $inventorySeen = @{}
  foreach ($row in @($Data.skills.inventory)) {
    $key = $row.source + '|' + $row.skill
    Assert-Equal "$Scenario inventory fields are safe" ((@($row.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'copies,description,name,skill,source,status') $true
    Assert-Equal "$Scenario inventory identity is unique" $inventorySeen.ContainsKey($key) $false
    $inventorySeen[$key] = $true
    Assert-Equal "$Scenario inventory status is explicit" ($row.status -in 'available', 'missing', 'ambiguous') $true
    Assert-Equal "$Scenario inventory copies are positive integer" (($row.copies -is [ValueType]) -and $row.copies -ge 1 -and [Math]::Floor([double]$row.copies) -eq $row.copies) $true
    if ($row.status -eq 'available') { Assert-Equal "$Scenario available inventory has a header" ([bool]($row.name -or $row.description)) $true }
    else {
      Assert-Equal "$Scenario unavailable inventory hides name" $row.name ''
      Assert-Equal "$Scenario unavailable inventory hides description" $row.description ''
    }
  }
}
function Assert-SkillPrivacy([string]$Scenario) {
  $artifactFiles = @(Get-ChildItem -LiteralPath $skillOutputRoot -Recurse -File | Where-Object { $_.Extension -in '.json', '.html' })
  foreach ($file in $artifactFiles) {
    $content = [IO.File]::ReadAllText($file.FullName)
    $safe = $true
    foreach ($sensitive in @('fixture-private-username', 'synthetic-private-workspace', 'unknown-private-title',
      'PRIVATE_SESSION_BODY_SENTINEL', 'PRIVATE_TOOL_ARGUMENT_SENTINEL', 'listed-only', 'mentioned-only',
      'PRIVATE_METADATA_BODY_SENTINEL', 'SYNTHETIC_CREDENTIAL_SENTINEL', 'MISSING_HEADER_BODY_SENTINEL',
      'UNOBSERVED_METADATA_SENTINEL', 'LINKED_METADATA_SENTINEL',
      '"arguments":', '"cmd":', '"command":', 'C:/Users/', 'C:\Users\', $skillSourceRoot,
      $skillSourceRoot.Replace('\', '\\'), $skillSourceRoot.Replace('\', '/'))) {
      if ($content.IndexOf($sensitive, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $safe = $false }
    }
    Assert-Equal "$Scenario output privacy $($file.Name)" $safe $true
  }
  $manifest = Read-JsonFile $skillManifestPath
  Assert-Equal "$Scenario skill manifest version" $manifest.version 5
  Assert-Equal "$Scenario skill manifest parser matches source" $manifest.parser $expectedParserFingerprint
  foreach ($entry in @($manifest.files)) {
    Assert-Equal "$Scenario skill manifest only safe keys" ((@($entry.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'cache,key,signature') $true
    Assert-Equal "$Scenario skill manifest hash key" ([string]$entry.key -match '^[a-f0-9]{64}$') $true
    Assert-Equal "$Scenario skill manifest cache key" $entry.cache $entry.key
    $record = Read-JsonFile (Join-Path $skillCacheRoot ([string]$entry.cache + '.json'))
    Assert-Equal "$Scenario skill cache parser matches source $($entry.key)" $record.parser $expectedParserFingerprint
  }
}
function Invoke-SkillGenerator([string]$Scenario, [int]$ExpectedReused, [int]$ExpectedReparsed,
  [bool]$IncrementalRead = $false, [string]$AsOfDate = '2026-09-28', [string[]]$ExpectedReparsedFiles = @(),
  [switch]$SkipChangedSourceCacheReads, [string]$GeneratorToRun = $generatorPath, [int]$ExpectedMigrated = 0) {
  Assert-Equal "$Scenario original generator hash remains fixed" (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorSha256AtStart
  $expectedCosts = Get-ExpectedRefreshCosts $Scenario $skillSourceRoot $skillCacheRoot $ExpectedReused $ExpectedReparsed $ExpectedReparsedFiles ([bool]$SkipChangedSourceCacheReads)
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $GeneratorToRun,
    '-SourceRoot', $skillSourceRoot, '-OutputRoot', $skillOutputRoot, '-MutexName', $mutexName, '-AsOfDate', $AsOfDate)
  $logPath = Join-Path $runRoot ($Scenario + '.log')
  $savedPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $messages = @(& $enginePath @arguments 2>&1)
    $processExit = $LASTEXITCODE
  } finally { $ErrorActionPreference = $savedPreference }
  $messages | Out-File -LiteralPath $logPath -Encoding UTF8
  $scenarios.Add([pscustomobject]@{ scenario = $Scenario; exit = $processExit; log = $logPath; generator = $GeneratorToRun; expectedParser = $expectedParserFingerprint })
  Assert-Equal "$Scenario process exit" $processExit 0
  $data = Read-JsonFile (Join-Path $skillOutputRoot 'codex-usage-dashboard-data.json')
  Assert-SkillData $Scenario $data $IncrementalRead $AsOfDate
  Assert-Equal "$Scenario skill source files" $data.refresh.files 11
  Assert-Equal "$Scenario skill reused files" $data.refresh.reused $ExpectedReused
  Assert-Equal "$Scenario skill reparsed files" $data.refresh.reparsed $ExpectedReparsed
  Assert-Equal "$Scenario migrated cache records" $data.refresh.migrated $ExpectedMigrated
  Assert-RefreshCosts $Scenario $data $expectedCosts $skillCacheRoot
  Assert-SkillPrivacy $Scenario
}
function Set-SyntheticCacheParser([string]$CacheDirectory, [string]$Parser) {
  $fullPath = [IO.Path]::GetFullPath($CacheDirectory)
  $runPrefix = $runRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($runPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Only this run synthetic caches may be mutated.' }
  $manifestFile = Join-Path $fullPath 'manifest.json'
  $manifest = Read-JsonFile $manifestFile
  foreach ($entry in @($manifest.files)) {
    $recordFile = Join-Path $fullPath ([string]$entry.cache + '.json')
    $record = Read-JsonFile $recordFile
    $record.parser = $Parser
    Write-JsonFile $recordFile $record
  }
  $manifest.parser = $Parser
  Write-JsonFile $manifestFile $manifest
}
function New-SkillMetadataFixtures {
  # Keep synthetic workspaces off the user-profile path so ancestor discovery stays local.
  $base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'synthetic-metadata-runs'))
  $ancestor = Get-Item -LiteralPath $PSScriptRoot
  while ($ancestor) {
    foreach ($relative in @('.agents\skills', '.codex\skills', 'skills')) {
      $candidate = Join-Path $ancestor.FullName $relative
      if (Test-Path -LiteralPath $candidate) { throw 'Metadata tests require a project ancestry without installed Skill directories.' }
    }
    $ancestor = $ancestor.Parent
  }
  $root = Join-Path $base $runId
  $source = Join-Path $root 'synthetic-skill-codex'
  $output = Join-Path $root 'generated'
  $workspaceA = Join-Path $root 'workspace-a'
  $workspaceB = Join-Path $root 'workspace-b'
  $projectA = Join-Path $workspaceA 'project'
  $projectB = Join-Path $workspaceB 'project'
  New-Item -ItemType Directory -Path $source, $output, $projectA, $projectB -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\skills\sessions') -Destination $source -Recurse
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\skills\archived_sessions') -Destination $source -Recurse
  $files = [Collections.Generic.List[string]]::new()
  $expected = @{}
  function Add-MetadataFixture([string]$Path, [string]$Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
    $files.Add($Path)
  }
  function Set-MetadataExpectation([string]$Source, [string]$Skill, [string]$Status, [string]$Name, [string]$Description) {
    $expected[$Source + '|' + $Skill] = @{ status = $Status; name = $Name; description = $Description }
  }
  $alphaPath = Join-Path $source 'skills\alpha\SKILL.md'
  Add-MetadataFixture $alphaPath ("---`nname: Alpha helper # note`ndescription: A short synthetic overview.`n---`nPRIVATE_METADATA_BODY_SENTINEL`n" + ('body text ' * 8192))
  Set-MetadataExpectation 'personal' 'alpha' 'available' 'Alpha helper' 'A short synthetic overview.'
  $unicodePath = Join-Path $source 'skills\.system\openai-docs\SKILL.md'
  $unicodeName = '中文说明："缓存"与读取国'
  $unicodeDescription = '这是一段用于验证 Windows PowerShell 5.1 与 PowerShell 7 读取无 BOM UTF-8 缓存的中文长简介。它包含"双引号"、''单引号''、中文顿号和句号，并要求冷缓存与暖缓存的名称、简介和字节保持一致。读取说明只是一种可观测代理指标，不代表实际调用或任务成功；最后一个字符紧接 JSON 结束双引号，末字符国'
  Add-MetadataFixture $unicodePath @'
---
name: "中文说明：\"缓存\"与读取国"
description: "这是一段用于验证 Windows PowerShell 5.1 与 PowerShell 7 读取无 BOM UTF-8 缓存的中文长简介。它包含\"双引号\"、'单引号'、中文顿号和句号，并要求冷缓存与暖缓存的名称、简介和字节保持一致。读取说明只是一种可观测代理指标，不代表实际调用或任务成功；最后一个字符紧接 JSON 结束双引号，末字符国"
---
PRIVATE_METADATA_BODY_SENTINEL
'@
  Set-MetadataExpectation 'system' 'openai-docs' 'available' $unicodeName $unicodeDescription
  Add-MetadataFixture (Join-Path $source 'skills\wrapped-double\SKILL.md') @'
---
name: "Quoted \"helper\""
description: "Quoted description: \"safe\"."
---
'@
  Set-MetadataExpectation 'personal' 'wrapped-double' 'available' 'Quoted "helper"' 'Quoted description: "safe".'
  Add-MetadataFixture (Join-Path $source 'skills\wrapped-single\SKILL.md') @'
---
name: 'Writer''s helper'
description: 'Single quoted # stays.'
---
'@
  Set-MetadataExpectation 'personal' 'wrapped-single' 'available' "Writer's helper" 'Single quoted # stays.'
  Add-MetadataFixture (Join-Path $source 'skills\wrapped-template\SKILL.md') @'
---
name: Literal helper
description: |
  First literal line.
  Second literal line.
---
'@
  Set-MetadataExpectation 'personal' 'wrapped-template' 'available' 'Literal helper' 'First literal line. Second literal line.'
  Add-MetadataFixture (Join-Path $source 'skills\custom-direct\SKILL.md') "---`ndescription: Description without a name.`n---`n"
  Set-MetadataExpectation 'personal' 'custom-direct' 'available' '' 'Description without a name.'
  Add-MetadataFixture (Join-Path $source 'skills\head-reader\SKILL.md') "---`nname: Safe name`ndescription: Saved at C:/Users/fixture-private-username/private`n---`n"
  Set-MetadataExpectation 'personal' 'head-reader' 'available' 'Safe name' ''
  Add-MetadataFixture (Join-Path $source 'skills\tail-reader\SKILL.md') "---`nname: For fixture-private-username`ndescription: Safe text remains.`n---`n"
  Set-MetadataExpectation 'personal' 'tail-reader' 'available' '' 'Safe text remains.'
  Add-MetadataFixture (Join-Path $source 'skills\more-reader\SKILL.md') "---`nname: api_key: SYNTHETIC_CREDENTIAL_SENTINEL`ndescription: password=SYNTHETIC_CREDENTIAL_SENTINEL`n---`n"
  Set-MetadataExpectation 'personal' 'more-reader' 'missing' '' ''
  Add-MetadataFixture (Join-Path $source 'skills\bat-reader\SKILL.md') "# No frontmatter`nname: Body Name`ndescription: MISSING_HEADER_BODY_SENTINEL`n"
  Set-MetadataExpectation 'personal' 'bat-reader' 'missing' '' ''
  Add-MetadataFixture (Join-Path $source 'skills\sed-reader\SKILL.md') ("---`nname: Header cannot close`nx: " + ('x' * 20000) + "`n---`nPRIVATE_METADATA_BODY_SENTINEL`n")
  Set-MetadataExpectation 'personal' 'sed-reader' 'missing' '' ''
  Add-MetadataFixture (Join-Path $source 'skills\shell-command\SKILL.md') "---`nname: Conflict one`ndescription: First variant.`n---`n"
  Add-MetadataFixture (Join-Path $root '.agents\skills\shell-command\SKILL.md') "---`nname: Conflict two`ndescription: Second variant.`n---`n"
  Set-MetadataExpectation 'personal' 'shell-command' 'ambiguous' '' ''
  $sameText = "---`nname: Same helper`ndescription: Identical metadata across two roots.`n---`n"
  Add-MetadataFixture (Join-Path $source 'skills\gc-reader\SKILL.md') $sameText
  Add-MetadataFixture (Join-Path $root '.agents\skills\gc-reader\SKILL.md') $sameText
  Set-MetadataExpectation 'personal' 'gc-reader' 'available' 'Same helper' 'Identical metadata across two roots.'
  $pluginText = "---`nname: Document helper`ndescription: Plugin description.`n---`n"
  foreach ($version in @('26.9', '26.10')) {
    Add-MetadataFixture (Join-Path $source ("plugins\cache\fixture-marketplace\documents\$version\skills\documents\SKILL.md")) $pluginText
  }
  Set-MetadataExpectation 'plugin' 'documents:documents' 'available' 'Document helper' 'Plugin description.'
  Add-MetadataFixture (Join-Path $workspaceA '.agents\skills\alpha\SKILL.md') @'
---
name: Workspace Alpha
description: >-
  Workspace operations.
  Keeps local conventions.
---
'@
  Set-MetadataExpectation 'workspace' 'alpha' 'available' 'Workspace Alpha' 'Workspace operations. Keeps local conventions.'
  Add-MetadataFixture (Join-Path $workspaceB '.codex\skills\local-check\SKILL.md') "---`nname: Local checker`ndescription: Workspace ancestor discovery.`n---`n"
  Set-MetadataExpectation 'workspace' 'local-check' 'available' 'Local checker' 'Workspace ancestor discovery.'
  Add-MetadataFixture (Join-Path $projectB 'skills\relative-check\SKILL.md') "---`nname: Relative checker`ndescription: Configured with JSON quoting.`n---`n"
  Set-MetadataExpectation 'workspace' 'relative-check' 'available' 'Relative checker' 'Configured with JSON quoting.'
  $candidateCount = $files.Count
  $inventoryExpected = @{}
  foreach ($key in $expected.Keys) { $inventoryExpected[$key] = $expected[$key] }
  $unobservedPath = Join-Path $source 'skills\unobserved-fresh\SKILL.md'
  Add-MetadataFixture $unobservedPath "---`nname: Unobserved helper`ndescription: Unobserved description.`n---`nPRIVATE_METADATA_BODY_SENTINEL`n"
  $inventoryExpected['personal|unobserved-fresh'] = @{ status = 'available'; name = 'Unobserved helper'; description = 'Unobserved description.' }
  $linkedTarget = Join-Path $root 'link-target'
  Add-MetadataFixture (Join-Path $linkedTarget 'SKILL.md') "---`nname: Linked helper`ndescription: LINKED_METADATA_SENTINEL`n---`n"
  $linkedPath = Join-Path $source 'skills\type-reader'
  New-Item -ItemType Junction -Path $linkedPath -Target $linkedTarget | Out-Null
  Set-MetadataExpectation 'personal' 'type-reader' 'missing' '' ''
  $configuration = "[projects.'$projectA']`ntrust_level = 'trusted'`n[projects." + (ConvertTo-Json -InputObject $projectB -Compress) + "]`ntrust_level = 'trusted'`n[projects.'\\metadata-test.invalid\private']`ntrust_level = 'trusted'`n"
  [IO.File]::WriteAllText((Join-Path $source 'config.toml'), $configuration, [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{ root = $root; sourceRoot = $source; outputRoot = $output; candidates = $candidateCount + 1; expected = $expected; inventoryExpected = $inventoryExpected; alphaPath = $alphaPath; unobservedPath = $unobservedPath; unicodePath = $unicodePath; unicodeName = $unicodeName; unicodeDescription = $unicodeDescription }
}
function Assert-SkillMetadataFixtures([string]$Scenario, [object]$Fixture, [int]$Reused, [int]$Reparsed) {
  $data = Read-JsonFile (Join-Path $skillOutputRoot 'codex-usage-dashboard-data.json')
  $cost = $data.refresh.skillMetadata
  Assert-Equal "$Scenario exact metadata candidates" $cost.candidates $Fixture.candidates
  Assert-Equal "$Scenario exact metadata reuse" $cost.reused $Reused
  Assert-Equal "$Scenario exact metadata reparsed" $cost.reparsed $Reparsed
  if ($Reparsed -eq 0) { Assert-Equal "$Scenario metadata warm cache reads zero source bytes" $cost.bytesRead 0 }
  else {
    Assert-Equal "$Scenario metadata source bytes were read" ($cost.bytesRead -gt 0) $true
    Assert-Equal "$Scenario metadata head reads are bounded" ($cost.bytesRead -le (17408 * $Reparsed)) $true
  }
  foreach ($row in @($data.skills.metadata)) {
    $key = $row.source + '|' + $row.skill
    $expected = if ($Fixture.expected.ContainsKey($key)) { $Fixture.expected[$key] } else { @{ status = 'missing'; name = ''; description = '' } }
    foreach ($field in @('status', 'name', 'description')) { Assert-Equal "$Scenario $key metadata $field" $row.$field $expected[$field] }
  }
  Assert-Equal "$Scenario inventory includes every current identity" @($data.skills.inventory).Count $Fixture.inventoryExpected.Count
  foreach ($row in @($data.skills.inventory)) {
    $key = $row.source + '|' + $row.skill
    Assert-Equal "$Scenario $key inventory is expected" $Fixture.inventoryExpected.ContainsKey($key) $true
    $expected = $Fixture.inventoryExpected[$key]
    foreach ($field in @('status', 'name', 'description')) { Assert-Equal "$Scenario $key inventory $field" $row.$field $expected[$field] }
    $copies = if ($key -in 'personal|shell-command', 'personal|gc-reader', 'plugin|documents:documents') { 2 } else { 1 }
    Assert-Equal "$Scenario $key inventory copies" $row.copies $copies
  }
  Assert-Equal "$Scenario junction target is not inventory" @($data.skills.inventory | Where-Object { $_.skill -eq 'type-reader' }).Count 0
  Assert-Equal "$Scenario unobserved Skill is not metadata" @($data.skills.metadata | Where-Object { $_.skill -eq 'unobserved-fresh' }).Count 0
  $cachePath = Join-Path $skillCacheRoot 'skill-metadata.json'
  $cache = Read-JsonFile $cachePath
  Assert-Equal "$Scenario independent metadata cache version" $cache.version 1
  Assert-Equal "$Scenario metadata cache contains current candidates" @($cache.entries).Count $Fixture.candidates
  Assert-Equal "$Scenario metadata cacheBytes matches file" $cost.cacheBytes (Get-Item -LiteralPath $cachePath).Length
  $cacheBytes = [IO.File]::ReadAllBytes($cachePath)
  Assert-Equal "$Scenario metadata cache exercises UTF-8 without BOM" ($cacheBytes.Length -ge 3 -and $cacheBytes[0] -eq 239 -and $cacheBytes[1] -eq 187 -and $cacheBytes[2] -eq 191) $false
  $unicodeKey = Get-PathKey ([IO.Path]::GetFullPath($Fixture.unicodePath).ToLowerInvariant())
  $unicodeEntry = @($cache.entries | Where-Object { $_.key -eq $unicodeKey })
  Assert-Equal "$Scenario Unicode metadata cache entry exists" $unicodeEntry.Count 1
  Assert-Equal "$Scenario Unicode cached name is preserved" $unicodeEntry[0].name $Fixture.unicodeName
  Assert-Equal "$Scenario Unicode cached long description is preserved" $unicodeEntry[0].description $Fixture.unicodeDescription
  foreach ($entry in @($cache.entries)) {
    Assert-Equal "$Scenario metadata cache fields" ((@($entry.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'description,key,name,signature') $true
    Assert-Equal "$Scenario metadata path is opaque hash" ([string]$entry.key -match '^[a-f0-9]{64}$') $true
  }
  $unobservedKey = Get-PathKey ([IO.Path]::GetFullPath($Fixture.unobservedPath).ToLowerInvariant())
  $expectedUnobservedCacheEntries = if ($Fixture.inventoryExpected.ContainsKey('personal|unobserved-fresh')) { 1 } else { 0 }
  Assert-Equal "$Scenario unobserved Skill cache follows current file" @($cache.entries | Where-Object { $_.key -eq $unobservedKey }).Count $expectedUnobservedCacheEntries
  Assert-Equal "$Scenario metadata discovery does not create Skill observations" @($data.skills.activity | Where-Object { $_.skill -eq 'unobserved-fresh' }).Count 0
}

try {
  Invoke-Generator '01-cold' 0 3
  Invoke-Generator '02-warm-including-empty-session' 3 0

  # Poison only test caches. The new version must recover the source totals.
  $manifest = Read-JsonFile $manifestPath
  $manifest.version = 3
  Write-JsonFile $manifestPath $manifest
  foreach ($entry in @($manifest.files)) {
    $recordPath = Join-Path $cacheRoot ([string]$entry.cache + '.json')
    Write-JsonFile $recordPath ([ordered]@{ version = 3; parser = $expectedParserFingerprint; events = @() })
  }
  Invoke-Generator '03-version-3-manifest-rebuild' 0 3

  $recordPath = Get-CacheRecordPath '01-main.jsonl'
  Write-JsonFile $recordPath ([ordered]@{ version = 3; parser = $expectedParserFingerprint; events = @() })
  Invoke-Generator '04-version-3-record-rebuild' 2 1 @('sessions\01-main.jsonl')

  $recordPath = Get-CacheRecordPath '01-main.jsonl'
  [IO.File]::WriteAllText($recordPath, '{ invalid json', [Text.UTF8Encoding]::new($false))
  Invoke-Generator '05-malformed-cache-rebuild' 2 1 @('sessions\01-main.jsonl')

  $recordPath = Get-CacheRecordPath '03-empty.jsonl'
  $validParser = (Read-JsonFile $recordPath).parser
  Write-JsonFile $recordPath ([ordered]@{ version = 5; parser = $validParser; events = [pscustomobject]@{} })
  Invoke-Generator '06-invalid-event-shape-rebuild' 2 1 @('sessions\03-empty.jsonl')

  [IO.File]::WriteAllText($manifestPath, '{ invalid manifest', [Text.UTF8Encoding]::new($false))
  Invoke-Generator '07-malformed-manifest-rebuild' 0 3

  $changedSource = Join-Path $sourceRoot 'sessions\01-main.jsonl'
  [IO.File]::AppendAllText($changedSource, [Environment]::NewLine + '{"type":"synthetic_ignored_event"}' + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  Invoke-Generator '08-only-changed-source-reparsed' 2 1 @('sessions\01-main.jsonl') -SkipChangedSourceCacheReads

  $skillSourceRoot = Join-Path $runRoot 'synthetic-skill-codex'
  $skillOutputRoot = Join-Path $runRoot 'skill-generated'
  $skillCacheRoot = Join-Path $skillOutputRoot '.codex-usage-dashboard-cache'
  $skillManifestPath = Join-Path $skillCacheRoot 'manifest.json'
  New-Item -ItemType Directory -Path $skillSourceRoot, $skillOutputRoot -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\skills\sessions') -Destination $skillSourceRoot -Recurse
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\skills\archived_sessions') -Destination $skillSourceRoot -Recurse
  Invoke-SkillGenerator '09-skill-cold' 0 11
  Invoke-SkillGenerator '10-skill-warm' 11 0

  # A version-4 cache may contain local paths. Migration must rebuild to safe version 5.
  $manifest = Read-JsonFile $skillManifestPath
  $manifest.version = 4
  foreach ($entry in @($manifest.files)) {
    $entry | Add-Member -NotePropertyName path -NotePropertyValue 'C:\Users\fixture-private-username\synthetic.jsonl'
  }
  Write-JsonFile $skillManifestPath $manifest
  Invoke-SkillGenerator '11-skill-version-4-migration' 0 11

  $skillRecordPath = Get-CacheRecordPath '02-second-task.jsonl' $skillSourceRoot $skillCacheRoot
  [IO.File]::WriteAllText($skillRecordPath, '{ invalid skill cache', [Text.UTF8Encoding]::new($false))
  Invoke-SkillGenerator '12-skill-corrupt-cache-recovery' 10 1 -ExpectedReparsedFiles @('sessions\02-second-task.jsonl')
  Invoke-SkillGenerator '13-skill-window-rolls-with-warm-cache' 11 0 $false '2026-09-29'

  $skillChangedSource = Join-Path $skillSourceRoot 'sessions\02-second-task.jsonl'
  $incrementalEvent = [ordered]@{
    timestamp = '2026-09-28T05:00:00Z'; type = 'response_item'; payload = [ordered]@{
      type = 'function_call'; name = 'exec_command'; call_id = 'incremental-read';
      arguments = '{"cmd":"Get-Content -Raw ''C:/Users/fixture-private-username/.codex/skills/incremental-new/SKILL.md''"}'
    }
  }
  [IO.File]::AppendAllText($skillChangedSource, [Environment]::NewLine + (ConvertTo-Json -InputObject $incrementalEvent -Depth 6 -Compress) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  Invoke-SkillGenerator '14-skill-incremental-new-read' 10 1 $true -ExpectedReparsedFiles @('sessions\02-second-task.jsonl') -SkipChangedSourceCacheReads

  # Same-format caches from an earlier parser cannot be reused after a source edit.
  $manifest = Read-JsonFile $skillManifestPath
  $manifest.parser = ('0' * 64)
  Write-JsonFile $skillManifestPath $manifest
  Invoke-SkillGenerator '15-manifest-parser-mismatch-rebuild' 0 11 $true

  $skillRecordPath = Get-CacheRecordPath '02-second-task.jsonl' $skillSourceRoot $skillCacheRoot
  $record = Read-JsonFile $skillRecordPath
  $record.parser = ('0' * 64)
  Write-JsonFile $skillRecordPath $record
  Invoke-SkillGenerator '16-record-parser-mismatch-rebuild' 10 1 $true -ExpectedReparsedFiles @('sessions\02-second-task.jsonl')

  # Only the explicitly verified former whole-script fingerprint can migrate hot.
  $legacyParser = '431a6296a6f8d46b7807bb2ed0f83e467d4e66f75616431d61d45a40be27e664'
  Set-SyntheticCacheParser $skillCacheRoot $legacyParser
  Invoke-SkillGenerator '17-verified-legacy-parser-hot-migration' 11 0 $true -ExpectedMigrated 11

  # Change only a copied generator and copied web source under this run directory.
  $isolatedProject = Join-Path $runRoot 'fingerprint-project'
  New-Item -ItemType Directory -Path $isolatedProject -Force | Out-Null
  $isolatedGenerator = Join-Path $isolatedProject 'refresh-ai-usage-dashboard.ps1'
  Copy-Item -LiteralPath $generatorPath -Destination $isolatedGenerator
  Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $generatorPath) 'web') -Destination $isolatedProject -Recurse
  $originalGeneratorText = [IO.File]::ReadAllText($isolatedGenerator)
  $aggregationOnlyText = $originalGeneratorText + [Environment]::NewLine + '# Synthetic aggregation-only edit outside event parsing functions.' + [Environment]::NewLine
  [IO.File]::WriteAllText($isolatedGenerator, $aggregationOnlyText, [Text.UTF8Encoding]::new($true))
  Assert-Equal '18 aggregation-only source change keeps parser fingerprint' (Get-TestParserFingerprint $aggregationOnlyText) $expectedParserFingerprint
  Invoke-SkillGenerator '18-aggregation-only-edit-reuses-events' 11 0 $true -GeneratorToRun $isolatedGenerator

  $readerFunction = Find-GeneratorFunction $aggregationOnlyText 'ReadEvents'
  $parserChangedText = $aggregationOnlyText.Insert($readerFunction.Body.Extent.StartOffset + 1,
    [Environment]::NewLine + '    # Synthetic read-function edit exercises parser invalidation.' + [Environment]::NewLine)
  $changedFingerprint = Get-TestParserFingerprint $parserChangedText
  Assert-Equal '19 read-function source change invalidates parser fingerprint' ($changedFingerprint -ne $expectedParserFingerprint) $true
  $expectedParserFingerprint = $changedFingerprint
  [IO.File]::WriteAllText($isolatedGenerator, $parserChangedText, [Text.UTF8Encoding]::new($true))
  Invoke-SkillGenerator '19-read-function-edit-reparses-events' 0 11 $true -GeneratorToRun $isolatedGenerator
  Invoke-SkillGenerator '20-changed-parser-warm-reuse' 11 0 $true -GeneratorToRun $isolatedGenerator

  # Legacy acceptance must not accidentally carry forward to a different parser.
  Set-SyntheticCacheParser $skillCacheRoot $legacyParser
  Invoke-SkillGenerator '21-changed-parser-rejects-legacy-fingerprint' 0 11 $true -GeneratorToRun $isolatedGenerator

  $metadataFixture = New-SkillMetadataFixtures
  $metadataRunRoot = $metadataFixture.root
  $skillSourceRoot = $metadataFixture.sourceRoot
  $skillOutputRoot = $metadataFixture.outputRoot
  $skillCacheRoot = Join-Path $skillOutputRoot '.codex-usage-dashboard-cache'
  $skillManifestPath = Join-Path $skillCacheRoot 'manifest.json'
  $expectedParserFingerprint = Get-TestParserFingerprint ([IO.File]::ReadAllText($generatorPath))
  # Process-local synthetic identity exercises username withholding without storing the real username.
  $env:USERNAME = 'fixture-private-username'
  Invoke-SkillGenerator '22-skill-metadata-cold' 0 11
  Assert-SkillMetadataFixtures '22-skill-metadata-cold' $metadataFixture 0 21
  $metadataBaseline = Read-JsonFile (Join-Path $skillOutputRoot 'codex-usage-dashboard-data.json')
  $baselineObservations = ConvertTo-Json -InputObject ([ordered]@{ rows = $metadataBaseline.skills.rows; activity = $metadataBaseline.skills.activity }) -Depth 8 -Compress
  $metadataCachePath = Join-Path $skillCacheRoot 'skill-metadata.json'
  $coldMetadataCacheSha256 = (Get-FileHash -LiteralPath $metadataCachePath -Algorithm SHA256).Hash

  Invoke-SkillGenerator '23-skill-metadata-warm' 11 0
  Assert-SkillMetadataFixtures '23-skill-metadata-warm' $metadataFixture 21 0
  Assert-Equal '23 Unicode metadata cache bytes are unchanged on warm reuse' (Get-FileHash -LiteralPath $metadataCachePath -Algorithm SHA256).Hash $coldMetadataCacheSha256

  $newDescription = 'Updated overview without new log reads.'
  [IO.File]::WriteAllText($metadataFixture.alphaPath, "---`nname: Alpha helper`ndescription: $newDescription`n---`nPRIVATE_METADATA_BODY_SENTINEL`n", [Text.UTF8Encoding]::new($false))
  $metadataFixture.expected['personal|alpha'].description = $newDescription
  $metadataFixture.inventoryExpected['personal|alpha'].description = $newDescription
  Invoke-SkillGenerator '24-skill-description-only-change' 11 0
  Assert-SkillMetadataFixtures '24-skill-description-only-change' $metadataFixture 20 1
  $metadataChanged = Read-JsonFile (Join-Path $skillOutputRoot 'codex-usage-dashboard-data.json')
  Assert-Equal '24 exact bytes for one short changed header' $metadataChanged.refresh.skillMetadata.bytesRead (Get-Item -LiteralPath $metadataFixture.alphaPath).Length
  $changedObservations = ConvertTo-Json -InputObject ([ordered]@{ rows = $metadataChanged.skills.rows; activity = $metadataChanged.skills.activity }) -Depth 8 -Compress
  Assert-Equal '24 metadata edits do not create or change observations' $changedObservations $baselineObservations

  $conflictPath = Join-Path $metadataRunRoot '.agents\skills\shell-command\SKILL.md'
  [IO.File]::WriteAllText($conflictPath, "---`nname: Conflict one`ndescription: First variant.`n---`n", [Text.UTF8Encoding]::new($false))
  $metadataFixture.expected['personal|shell-command'] = @{ status = 'available'; name = 'Conflict one'; description = 'First variant.' }
  $metadataFixture.inventoryExpected['personal|shell-command'] = $metadataFixture.expected['personal|shell-command']
  Invoke-SkillGenerator '25-identical-metadata-variants-merge' 11 0
  Assert-SkillMetadataFixtures '25-identical-metadata-variants-merge' $metadataFixture 20 1

  Invoke-SkillGenerator '26-metadata-date-independent-of-statistics-window' 11 0 $false '2026-09-29'
  Assert-SkillMetadataFixtures '26-metadata-date-independent-of-statistics-window' $metadataFixture 21 0

  [IO.File]::WriteAllText((Join-Path $skillCacheRoot 'skill-metadata.json'), '{ invalid metadata cache', [Text.UTF8Encoding]::new($false))
  Invoke-SkillGenerator '27-metadata-cache-recovery-keeps-log-cache' 11 0
  Assert-SkillMetadataFixtures '27-metadata-cache-recovery-keeps-log-cache' $metadataFixture 0 21

  # A version-1 cache from the observed-only implementation remains reusable.
  $legacyMetadataCache = Read-JsonFile $metadataCachePath
  $unobservedKey = Get-PathKey ([IO.Path]::GetFullPath($metadataFixture.unobservedPath).ToLowerInvariant())
  $legacyMetadataCache.entries = @($legacyMetadataCache.entries | Where-Object { $_.key -ne $unobservedKey })
  Write-JsonFile $metadataCachePath $legacyMetadataCache
  Invoke-SkillGenerator '28-observed-only-metadata-cache-upgrade' 11 0
  Assert-SkillMetadataFixtures '28-observed-only-metadata-cache-upgrade' $metadataFixture 20 1

  # Restoring a conflicting copy changes only current descriptions.
  [IO.File]::WriteAllText($conflictPath, "---`nname: Conflict two`ndescription: Second variant.`n---`n", [Text.UTF8Encoding]::new($false))
  $metadataFixture.expected['personal|shell-command'] = @{ status = 'ambiguous'; name = ''; description = '' }
  $metadataFixture.inventoryExpected['personal|shell-command'] = $metadataFixture.expected['personal|shell-command']
  Invoke-SkillGenerator '29-current-copies-conflict' 11 0
  Assert-SkillMetadataFixtures '29-current-copies-conflict' $metadataFixture 20 1

  # Removing a never-observed file removes its current inventory identity only.
  Remove-Item -LiteralPath $metadataFixture.unobservedPath -Force
  $metadataFixture.inventoryExpected.Remove('personal|unobserved-fresh')
  $metadataFixture.candidates--
  Invoke-SkillGenerator '30-unobserved-file-removed' 11 0
  Assert-SkillMetadataFixtures '30-unobserved-file-removed' $metadataFixture 20 0
  $removedData = Read-JsonFile (Join-Path $skillOutputRoot 'codex-usage-dashboard-data.json')
  Assert-Equal '30 removed file never enters observed metadata' @($removedData.skills.metadata | Where-Object { $_.skill -eq 'unobserved-fresh' }).Count 0

  # A current directory can be shown when the synthetic source has no session logs.
  $emptyMetadataRoot = Join-Path (Split-Path -Parent $metadataFixture.root) ($runId + '-empty')
  $emptySourceRoot = Join-Path $emptyMetadataRoot 'synthetic-codex'
  $emptyOutputRoot = Join-Path $emptyMetadataRoot 'generated'
  $emptySkillPath = Join-Path $emptySourceRoot 'skills\inventory-only\SKILL.md'
  New-Item -ItemType Directory -Path (Split-Path -Parent $emptySkillPath), $emptyOutputRoot -Force | Out-Null
  [IO.File]::WriteAllText($emptySkillPath, "---`nname: Inventory only`ndescription: Current local header.`n---`nPRIVATE_METADATA_BODY_SENTINEL`n", [Text.UTF8Encoding]::new($false))
  foreach ($pass in @('31-empty-sessions-cold', '32-empty-sessions-warm')) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $generatorPath,
      '-SourceRoot', $emptySourceRoot, '-OutputRoot', $emptyOutputRoot, '-MutexName', $mutexName, '-AsOfDate', '2026-09-28')
    $messages = @(& $enginePath @arguments 2>&1)
    $messages | Out-File -LiteralPath (Join-Path $runRoot ($pass + '.log')) -Encoding UTF8
    Assert-Equal "$pass process exit" $LASTEXITCODE 0
    $emptyData = Read-JsonFile (Join-Path $emptyOutputRoot 'codex-usage-dashboard-data.json')
    Assert-Equal "$pass no Skill activity" @($emptyData.skills.activity).Count 0
    Assert-Equal "$pass no observed metadata" @($emptyData.skills.metadata).Count 0
    Assert-Equal "$pass inventory schema" $emptyData.skills.inventorySchema 1
    $only = @($emptyData.skills.inventory | Where-Object { $_.skill -eq 'inventory-only' -and $_.source -eq 'personal' })
    Assert-Equal "$pass current Skill is listed" $only.Count 1
    Assert-Equal "$pass current header is available" $only[0].status 'available'
    Assert-Equal "$pass current copies" $only[0].copies 1
    $emptyJson = [IO.File]::ReadAllText((Join-Path $emptyOutputRoot 'codex-usage-dashboard-data.json'))
    Assert-Equal "$pass inventory omits body and local path" ($emptyJson -notmatch 'PRIVATE_METADATA_BODY_SENTINEL|fixture-private-username|C:[\\/]|D:[\\/]') $true
    $expectedReuse = if ($pass -like '*warm') { 1 } else { 0 }
    Assert-Equal "$pass metadata cache reuse" $emptyData.refresh.skillMetadata.reused $expectedReuse
    Assert-Equal "$pass metadata cache read" $emptyData.refresh.skillMetadata.reparsed (1 - $expectedReuse)
  }
  Assert-Equal '32 original generator hash is unchanged after all scenarios' (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorSha256AtStart
} catch {
  $failure = $_.Exception.Message
} finally {
  $env:USERNAME = $originalUsername
  $summary = [ordered]@{
    passed = ($null -eq $failure)
    runtime = $PSVersionTable.PSVersion.ToString()
    engine = $enginePath
    generator = $generatorPath
    generatorSha256 = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
    generatorSha256AtStart = $generatorSha256AtStart
    expectedGeneratorSha256 = $ExpectedGeneratorSha256
    testRun = $runRoot
    sourceRoot = $sourceRoot
    outputRoot = $outputRoot
    metadataTestRoot = $metadataRunRoot
    emptyMetadataTestRoot = $emptyMetadataRoot
    assertionCount = $assertions.Count
    failure = $failure
    scenarios = @($scenarios.ToArray())
    assertions = @($assertions.ToArray())
    artifactPolicy = 'Synthetic inputs, output and logs are retained under testRun, metadataTestRoot and emptyMetadataTestRoot. The metadata workspaces are isolated under ignored synthetic-metadata-runs with ancestors checked for installed Skill directories. No cleanup or production writes occur.'
  }
  $resultPath = Join-Path $runRoot 'results.json'
  Write-JsonFile $resultPath $summary
  Write-Output ('RESULT: ' + $resultPath)
  Write-Output ('RUNTIME: ' + $summary.runtime + '; ASSERTIONS: ' + $assertions.Count + '; PASSED: ' + $summary.passed)
}
if ($null -ne $failure) {
  Write-Error $failure -ErrorAction Continue
  exit 1
}
