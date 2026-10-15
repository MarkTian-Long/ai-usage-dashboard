# Synthetic behavior regressions for refresh optimizations; no timing thresholds.
# All fixture mutations stay below a newly created child of TestOutputRoot.
[CmdletBinding()]
param(
  [string]$Generator = '',
  [string]$ExpectedGeneratorSha256 = '',
  [string]$TestOutputRoot = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
if (-not $TestOutputRoot) { $TestOutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'usage-refresh-tests' }
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
$generatorHash = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedGeneratorSha256 -and $generatorHash -ne $ExpectedGeneratorSha256) {
  throw 'Generator SHA256 differs from the explicitly pinned test source.'
}
$engine = (Get-Process -Id $PID).Path
$outputBase = [IO.Path]::GetFullPath($TestOutputRoot)
do { $runRoot = [IO.Path]::GetFullPath((Join-Path $outputBase ('r' + [Guid]::NewGuid().ToString('N').Substring(0, 6)))) }
while (Test-Path -LiteralPath $runRoot)
$basePrefix = $outputBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $runRoot.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Test run directory must be a child of TestOutputRoot.'
}
New-Item -ItemType Directory -Path $runRoot | Out-Null
$checks = 0
$scenarios = [Collections.Generic.List[object]]::new()
$mutex = 'Local\CodexRefreshPerformance_' + [Guid]::NewGuid().ToString('N')
$failure = $null
$bodySentinel = 'PRIVATE_REFRESH_BODY_SENTINEL'

function Check([string]$Name, $Actual, $Expected) {
  $equal = if ($null -eq $Expected) { $null -eq $Actual } else { $Actual -ceq $Expected }
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
function Write-Json([string]$Path, $Value) {
  [IO.File]::WriteAllText((Assert-TestPath $Path), (ConvertTo-Json -InputObject $Value -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
}
function Write-Text([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText((Assert-TestPath $Path), $Text, [Text.UTF8Encoding]::new($false))
}
function Read-Json([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Text-Hash([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')).ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Move-TestFile([string]$Source, [string]$Destination) {
  Move-Item -LiteralPath (Assert-TestPath $Source) -Destination (Assert-TestPath $Destination)
}
function Remove-TestFile([string]$Path) { Remove-Item -LiteralPath (Assert-TestPath $Path) -Force }
function Sum($Rows, [string]$Field = 'total') {
  $sum = ($Rows | Measure-Object -Property $Field -Sum).Sum
  if ($null -eq $sum) { return [long]0 }
  [long]$sum
}
function Field-Text($Item, [string]$Name) {
  $property = $Item.PSObject.Properties[$Name]
  if ($null -ne $property -and $null -ne $property.Value) { [string]$property.Value }
}
function Reference-AddSource([object[]]$Events, [bool]$Historical, $State) {
  # Frozen pre-optimization AddSourceEvents behavior from main 2d7e1c4.
  $pending = @{}
  foreach ($event in $Events) {
    $session = [string]$event.s
    if ($event.k -eq 'token_usage_record') { $pending[$session] = $event }
    elseif ($event.k -in 'task_started', 'task_complete') { $pending.Remove($session) }
    elseif ($event.k -eq 'token_count') {
      $proven = $false
      if ([int64]$event.l[0] + [int64]$event.l[2] -gt 0) {
        $candidate = $pending[$session]
        if ($candidate -and (Field-Text $candidate turn) -eq (Field-Text $event turn) -and
            (@($candidate.l)[0..3] -join '|') -eq (@($event.l)[0..3] -join '|')) {
          $proven = $true; $State.matched[[string]$candidate.r] = $true
        }
        $pending.Remove($session)
      }
      $event | Add-Member -NotePropertyName provenResponse -NotePropertyValue $proven -Force
    }
    $identity = @($event.s, $event.a, $event.k, $event.mo, $event.ef, $event.sc, $event.turn, $event.r,
      (@($event.l) -join ','), (@($event.t) -join ','), $event.du, $event.ft, $event.hf, $event.er, $event.w, $event.skill, $event.source) | ConvertTo-Json -Compress
    $first = $State.identities.Add($identity)
    if ($Historical -and -not $first) { continue }
    $State.all.Add($event)
  }
}
function New-SourceState {
  @{ identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);
    all = [Collections.Generic.List[object]]::new(); matched = @{} }
}
function Test-AddSourceHelper($Helper) {
  $method = $Helper.GetMethod('AddSource')
  Check 'compiled helper exposes source-order aggregation' ($null -ne $method) $true
  $template = [pscustomobject][ordered]@{ s = 'synthetic-source'; a = '2026-10-13T00:00:00.0000000Z'; i = 1;
    k = 'compacted'; mo = 'fixture-model'; ef = 'high'; sc = 'task'; turn = 'synthetic-turn'; w = 'synthetic-window' }
  $variants = [Collections.Generic.List[object]]::new()
  foreach ($value in @(7, 'abc', [pscustomobject]@{ value = 'synthetic' }, @{ value = 'synthetic' }, [object[]]@(1, 2, 3))) {
    $item = $template.PSObject.Copy()
    $item.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('l', $value))
    $item.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('t', $value))
    $variants.Add([pscustomobject]@{ name = 'non-token-lt-' + $variants.Count;
      batches = @(@{ historical = $false; events = @($item) }, @{ historical = $true; events = @($item) }) })
  }
  $record = [pscustomobject][ordered]@{ s = 'synthetic-source'; a = '2026-10-13T00:00:01.0000000Z'; i = 2;
    k = 'token_usage_record'; mo = 'fixture-model'; ef = 'high'; sc = 'task'; turn = 'synthetic-turn';
    r = ('a' * 64); l = @(10, 2, 1, 0, 11); t = @(10, 2, 1, 0, 11) }
  $count = $record.PSObject.Copy(); $count.k = 'token_count'; $count.a = '2026-10-13T00:00:02.0000000Z'; $count.i = 3
  $boundary = [pscustomobject][ordered]@{ s = 'synthetic-source'; a = '2026-10-13T00:00:01.5000000Z'; i = 3;
    k = 'task_started'; mo = 'fixture-model'; ef = 'high'; sc = 'task'; turn = 'synthetic-turn' }
  $zero = $count.PSObject.Copy(); $zero.l = @(0, 0, 0, 0, 0); $zero.t = @(0, 0, 0, 0, 0)
  $variants.Add([pscustomobject]@{ name = 'matched-before-historical-copy-removal';
    batches = @(@{ historical = $false; events = @($count) }, @{ historical = $true; events = @($record, $count) }) })
  $variants.Add([pscustomobject]@{ name = 'task-boundary-clears-pending';
    batches = @(@{ historical = $false; events = @($record, $boundary, $count) }) })
  $variants.Add([pscustomobject]@{ name = 'zero-count-retains-pending';
    batches = @(@{ historical = $false; events = @($record, $zero, $count) }) })
  $variants.Add([pscustomobject]@{ name = 'pending-is-local-to-each-source';
    batches = @(@{ historical = $false; events = @($record) }, @{ historical = $false; events = @($count) }) })
  $composed = $record.PSObject.Copy(); $composed.turn = [string][char]0xE9
  $decomposed = $count.PSObject.Copy(); $decomposed.turn = 'e' + [char]0x301
  $variants.Add([pscustomobject]@{ name = 'turns-keep-powershell-invariant-comparison';
    batches = @(@{ historical = $false; events = @($composed, $decomposed) }) })
  foreach ($variant in $variants) {
    $reference = New-SourceState; $optimized = New-SourceState
    foreach ($batch in $variant.batches) {
      # Aggregation mutates only outer provenResponse properties. Copy the outer
      # PSObjects so optional scalar/collection types and timestamp strings stay
      # identical; a JSON round trip would normalize those types on PS 7.
      $before = @(foreach ($item in $batch.events) { $item.PSObject.Copy() })
      $after = @(foreach ($item in $batch.events) { $item.PSObject.Copy() })
      Reference-AddSource $before $batch.historical $reference
      $arguments = [object[]]::new(6)
      $arguments[0] = [object[]]$after; $arguments[1] = [bool]$batch.historical
      $arguments[2] = $optimized.identities; $arguments[3] = $optimized.all; $arguments[4] = $optimized.matched
      $arguments[5] = { param($parts) 'J' + ($parts | ConvertTo-Json -Compress) }
      $null = $method.Invoke($null, $arguments)
    }
    $beforeJson = ConvertTo-Json -InputObject $reference.all.ToArray() -Depth 12 -Compress
    $afterJson = ConvertTo-Json -InputObject $optimized.all.ToArray() -Depth 12 -Compress
    Check ($variant.name + ' preserves ordered events and proven flags') $afterJson $beforeJson
    Check ($variant.name + ' preserves exact-copy equivalence classes') $optimized.identities.Count $reference.identities.Count
    Check ($variant.name + ' preserves response matching count') $optimized.matched.Count $reference.matched.Count
    foreach ($key in $reference.matched.Keys) { Check ($variant.name + ' preserves matched response identity') $optimized.matched[$key] $reference.matched[$key] }
  }
  $script:scenarios.Add([ordered]@{ name = 'source-order-helper-equivalence'; passed = $true; variants = $variants.Count })
}

function Test-IdentityHelper {
  # Compile only the literal helper obtained from the Add-Type AST, never the
  # generator body. Rename its type to avoid accidentally reusing an older DLL.
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($script:generatorPath, [ref]$tokens, [ref]$parseErrors)
  Check 'generator parses before helper extraction' $parseErrors.Count 0
  $commands = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type'
  }, $true))
  $definitions = [Collections.Generic.List[string]]::new()
  foreach ($command in $commands) {
    for ($index = 0; $index -lt $command.CommandElements.Count - 1; $index++) {
      $element = $command.CommandElements[$index]
      $value = $command.CommandElements[$index + 1]
      if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'TypeDefinition' -and
          $value -is [Management.Automation.Language.StringConstantExpressionAst] -and $value.Value -match 'class AiUsageEventOpsV1\b') {
        $definitions.Add($value.Value)
      }
    }
  }
  Check 'exactly one literal event helper is extracted' $definitions.Count 1
  $typeName = 'AiUsageEventOpsTest_' + [Guid]::NewGuid().ToString('N')
  $definition = [regex]::Replace($definitions[0], '\bAiUsageEventOpsV1\b', $typeName)
  Add-Type -TypeDefinition $definition
  $helper = $typeName -as [type]
  Check 'extracted helper compiled' ($null -ne $helper) $true
  $method = $helper.GetMethod('StringIdentity')
  Check 'compiled helper exposes the identity method' ($null -ne $method) $true
  $base = [object[]]@('synthetic-thread', '2026-10-13T00:00:00.0000000Z', 'token_count', 'fixture-model', 'high', 'task',
    'synthetic-turn', $null, '10,2,1,0,11', '10,2,1,0,11', $null, $null, $null, $null, $null, $null, $null)
  Check 'identity fixture covers all seventeen fields' $base.Count 17
  $cases = [Collections.Generic.List[object]]::new()
  $cases.Add([pscustomobject]@{ name = 'base'; fields = $base.Clone(); typed = $false })
  $cases.Add([pscustomobject]@{ name = 'same-values'; fields = $base.Clone(); typed = $false })
  for ($index = 0; $index -lt $base.Count; $index++) {
    $fields = $base.Clone(); $fields[$index] = 'changed-' + $index
    $cases.Add([pscustomobject]@{ name = 'field-' + $index; fields = $fields; typed = $false })
  }
  $unicode = [string][char]0x6D4B + [char]0x8BD5 + [char]0xD83D + [char]0xDE80
  foreach ($text in @('', '|', 'N', 'S0:', 'alpha:beta|high', 'quote"slash\', ('line' + [char]10 + 'break'),
      ('nul' + [char]0 + 'value'), $unicode)) {
    $fields = $base.Clone(); $fields[16] = $text
    $cases.Add([pscustomobject]@{ name = 'text-' + $cases.Count; fields = $fields; typed = $false })
  }
  $left = $base.Clone(); $left[3] = 'alpha|beta'; $left[4] = 'high'
  $right = $base.Clone(); $right[3] = 'alpha'; $right[4] = 'beta|high'
  Check 'fixture exposes a naive delimiter collision' (($left -join '|') -ceq ($right -join '|')) $true
  $cases.Add([pscustomobject]@{ name = 'delimiter-left'; fields = $left; typed = $false })
  $cases.Add([pscustomobject]@{ name = 'delimiter-right'; fields = $right; typed = $false })
  foreach ($typedValue in @($false, $true, 0, [long]42, [double]1.25, [decimal]1.25, [pscustomobject]@{ value = 'synthetic' })) {
    $fields = $base.Clone(); $fields[10] = $typedValue
    $cases.Add([pscustomobject]@{ name = 'typed-' + $cases.Count; fields = $fields; typed = $true })
  }
  $results = [Collections.Generic.List[object]]::new()
  foreach ($case in $cases) {
    $arguments = [object[]]::new(1); $arguments[0] = $case.fields
    $key = $method.Invoke($null, $arguments)
    Check ($case.name + ' fast helper handles only strings and null') ($null -eq $key) $case.typed
    $old = $case.fields | ConvertTo-Json -Compress
    if ($null -eq $key) { $key = 'J' + $old }
    $results.Add([pscustomobject]@{ name = $case.name; old = $old; key = $key })
  }
  foreach ($leftCase in $results) {
    foreach ($rightCase in $results) {
      Check ($leftCase.name + '/' + $rightCase.name + ' preserves JSON equality') ($leftCase.key -ceq $rightCase.key) ($leftCase.old -ceq $rightCase.old)
    }
  }
  $script:scenarios.Add([ordered]@{ name = 'identity-helper-equivalence'; passed = $true; variants = $results.Count })
  $jsonType=(Get-Command ConvertTo-Json).ImplementingType.Assembly.GetType('Microsoft.PowerShell.Commands.JsonObject')
  $null=$helper.GetMethod('ConfigureIdentitySerializer').Invoke($null,@(($PSVersionTable.PSVersion.Major -le 5),$jsonType))
  $identityMethod=$helper.GetMethod('EventIdentity',[Reflection.BindingFlags]'NonPublic,Static')
  foreach($value in @($false,$true,[long]9007199254740991,[decimal]1.00,[double]1,[double]1.25,[double]1e-20,[double]1e20,([double](-1)*0))) {
    $fields=$base.Clone();$fields[10]=$value
    $args=[object[]]::new(2);$args[0]=$fields;$args[1]={param($parts) 'J'+($parts|ConvertTo-Json -Compress)}
    Check 'native scalar JSON preserves host null and numeric serialization' ($identityMethod.Invoke($null,$args)) ('J'+($fields|ConvertTo-Json -Compress))
  }
  Test-AddSourceHelper $helper
  Test-ReleaseCoveredRecordsHelper $helper
}

function Test-ReleaseCoveredRecordsHelper($Helper) {
  $method = $Helper.GetMethod('ReleaseCoveredRecords')
  Check 'compiled helper exposes working-memory release' ($null -ne $method) $true
  $events = [Collections.Generic.List[object]]::new()
  foreach ($spec in @(
      @('thread-a', 'task_started', '', 1),
      @('thread-a', 'token_usage_record', 'matched-a', 2),
      @('thread-a', 'token_usage_record', 'matched-b', 3),
      @('thread-a', 'token_usage_record', 'legacy-unmatched', 4),
      @('thread-b', 'token_usage_record', 'matched-a', 5),
      @('thread-b', 'token_usage_record', 'matched-b', 6),
      @('thread-c', 'token_usage_record', 'unmatched', 7),
      @('thread-a', 'token_count', 'matched-b', 8))) {
    $events.Add([pscustomobject]@{ s = $spec[0]; k = $spec[1]; r = $spec[2]; i = $spec[3] })
  }
  $arguments = [object[]]::new(2); $arguments[0] = $events; $arguments[1] = @{}
  Check 'no records are released without proven matches' ($method.Invoke($null, $arguments)) 0
  Check 'unmatched event order is unchanged' (($events | ForEach-Object i) -join ',') '1,2,3,4,5,6,7,8'
  # Matches may be established by a later source. Release runs only after all
  # sources have contributed, and must not infer coverage from numeric states.
  $arguments[1] = @{ 'matched-a' = $true; 'matched-b' = $true }
  Check 'only additional proven records are released' ($method.Invoke($null, $arguments)) 2
  Check 'all other records preserve their order' (($events | ForEach-Object i) -join ',') '1,2,4,5,7,8'
  Check 'covered-only thread retains its first record for aliases' @($events | Where-Object s -eq 'thread-b')[0].i 5
  Check 'legacy coverage candidates remain available to aggregation' @($events | Where-Object r -eq 'legacy-unmatched').Count 1
  Check 'all original thread groups remain' (($events | Group-Object s | ForEach-Object Name) -join ',') 'thread-a,thread-b,thread-c'
  Check 'release is idempotent' ($method.Invoke($null, $arguments)) 0
  $script:scenarios.Add([ordered]@{ name = 'covered-record-working-memory'; passed = $true })
}

function History-State([string]$Output) {
  $namespaces = @(Get-ChildItem -LiteralPath (Join-Path $Output '.codex-usage-dashboard-history') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') })
  Check 'fixture has exactly one history namespace' $namespaces.Count 1
  $manifestPath = Join-Path $namespaces[0].FullName 'manifest.json'
  $manifest = Read-Json $manifestPath
  Check 'fixture has exactly one committed history entry' @($manifest.files).Count 1
  $entry = @($manifest.files)[0]
  [pscustomobject]@{ manifestPath = $manifestPath; manifest = $manifest; entry = $entry;
    blobPath = Join-Path $namespaces[0].FullName ($entry.hash + '.json') }
}
function Check-HistoryPrivacy([string]$Output) {
  foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $Output '.codex-usage-dashboard-history') -Recurse -File -Filter '*.json')) {
    $text = [IO.File]::ReadAllText($file.FullName)
    Check 'no unknown body property enters durable history' ($text.Contains($script:bodySentinel)) $false
    Check 'no fixture local path enters durable history' ($text -match '(?i)[a-z]:[\\/]') $false
  }
}
function Run([string]$Name, $Case, [long]$Total, [int]$HistoryReused, [int]$SourceReused, [int]$Reparsed,
    [int]$Retained = 0, [switch]$ExpectFailure) {
  Check "$Name fixed generator source" (Get-FileHash -LiteralPath $script:generatorPath -Algorithm SHA256).Hash $script:generatorHash
  $sourceHashes = @(Get-ChildItem -LiteralPath $Case.source -Recurse -File -Filter '*.jsonl' | ForEach-Object {
    @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  })
  $dataPath = Join-Path $Case.output 'codex-usage-dashboard-data.json'
  $artifacts = @($dataPath, (Join-Path $Case.output 'codex-usage-dashboard.html'))
  $before = @{}
  if ($ExpectFailure) {
    $artifacts += (History-State $Case.output).manifestPath
    foreach ($path in $artifacts) { $before[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
  }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:generatorPath,
    '-SourceRoot', $Case.source, '-OutputRoot', $Case.output, '-MutexName', $script:mutex, '-AsOfDate', '2026-10-15')
  $savedPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $messages = @(& $script:engine @arguments 2>&1); $exitCode = $LASTEXITCODE }
  finally { $ErrorActionPreference = $savedPreference }
  $messages | Out-File -LiteralPath (Assert-TestPath (Join-Path $script:runRoot ($Name + '.log'))) -Encoding UTF8
  foreach ($item in $sourceHashes) {
    Check "$Name source file still exists" (Test-Path -LiteralPath $item.path) $true
    Check "$Name source file unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash
  }
  if ($ExpectFailure) {
    Check "$Name damaged history is rejected" ($exitCode -ne 0) $true
    foreach ($path in $artifacts) {
      Check "$Name previous committed artifact is unchanged" (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash $before[$path]
    }
    $script:scenarios.Add([ordered]@{ name = $Name; passed = $true; expectedFailure = $true })
    return
  }
  if ($exitCode -ne 0) { throw ("$Name generator failed: " + ($messages -join [Environment]::NewLine)) }
  $data = Read-Json $dataPath
  Check "$Name exact total" (Sum $data.usage) $Total
  Check "$Name source cache reuse" $data.refresh.reused $SourceReused
  Check "$Name source reparsing" $data.refresh.reparsed $Reparsed
  Check "$Name bound history write reuse" $data.refresh.historyWritesReused $HistoryReused
  Check "$Name retained history count" $data.refresh.history.retainedFiles $Retained
  Check "$Name no cache import" $data.refresh.history.recoveredFiles 0
  Check "$Name no skipped recovery cache" $data.refresh.history.skippedCaches 0
  if ($Retained) { Check "$Name earliest retained day" $data.refresh.history.startDate '2026-08-05' }
  else { Check "$Name no invented retained day" $data.refresh.history.startDate $null }
  Check "$Name exact token composition" @($data.usage | Where-Object {
    $_.total -ne $_.input + $_.output -or $_.input -ne $_.cached + $_.fresh -or $_.reasoning -gt $_.output
  }).Count 0
  Check "$Name no unknown body property enters data" ([IO.File]::ReadAllText($dataPath).Contains($script:bodySentinel)) $false
  Check-HistoryPrivacy $Case.output
  $script:scenarios.Add([ordered]@{ name = $Name; passed = $true; expectedFailure = $false; total = $Total })
  $data
}

try {
  Test-IdentityHelper
  $caseRoot = Assert-TestPath (Join-Path $runRoot 'a')
  $source = Join-Path $caseRoot 's'; $output = Join-Path $caseRoot 'o'
  $sessions = Join-Path $source 'sessions'
  foreach ($directory in @($sessions, $output)) { New-Item -ItemType Directory -Path (Assert-TestPath $directory) -Force | Out-Null }
  $case = [pscustomobject]@{ root = $caseRoot; source = $source; output = $output }
  $sourcePath = Join-Path $sessions 'a.jsonl'; $parked = Join-Path $caseRoot 'u'
  $amount = [ordered]@{ input_tokens = 10; cached_input_tokens = 2; output_tokens = 1; reasoning_output_tokens = 0; total_tokens = 11 }
  $events = @(
    [ordered]@{ timestamp = '2026-08-05T00:00:00Z'; type = 'session_meta'; payload = @{ id = 'private-refresh-thread'; cwd = 'C:\private-refresh-source' } },
    [ordered]@{ timestamp = '2026-08-05T00:00:01Z'; type = 'turn_context'; payload = @{ turn_id = 'private-refresh-turn'; model = 'fixture-refresh-model'; effort = 'high' } },
    [ordered]@{ timestamp = '2026-08-05T00:00:02Z'; type = 'event_msg'; payload = @{ type = 'token_count'; info = @{ last_token_usage = $amount; total_token_usage = $amount } } }
  )
  $lines = @($events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress })
  [IO.File]::WriteAllLines((Assert-TestPath $sourcePath), $lines, [Text.UTF8Encoding]::new($false))
  $null = Run '01-cold' $case 11 0 0 1
  $history = History-State $output
  $oldHash = $history.entry.hash
  $oldBlob = $history.blobPath
  Check 'cold history binds a cache proof' ($history.entry.cacheProof -match '^[a-f0-9]{64}$') $true
  $history.manifest.files[0].PSObject.Properties.Remove('cacheProof')
  Write-Json $history.manifestPath $history.manifest
  $null = Run '02-legacy-proof-upgrade' $case 11 0 1 0
  $history = History-State $output
  Check 'legacy history receives a cache proof' ($history.entry.cacheProof -match '^[a-f0-9]{64}$') $true
  Check 'proof upgrade preserves the original history content' $history.entry.hash $oldHash
  $oldProof = $history.entry.cacheProof
  $null = Run '03-warm-proof-reuse' $case 11 1 1 0

  # The source itself stays byte-for-byte and metadata-identical. A valid cache
  # change must still invalidate the proof, persist projected events, and survive
  # source migration. Unknown properties must never be copied into history.
  $sourceSignature = '{0}|{1}' -f (Get-Item -LiteralPath $sourcePath).Length, (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc.Ticks
  $cacheRoot = Join-Path $output '.codex-usage-dashboard-cache'
  $cacheIndex = Read-Json (Join-Path $cacheRoot 'manifest.json')
  Check 'fixture has exactly one current cache entry' @($cacheIndex.files).Count 1
  $cachePath = Join-Path $cacheRoot ($cacheIndex.files[0].cache + '.json')
  $cache = Read-Json $cachePath
  $counts = @($cache.events | Where-Object k -eq 'token_count')
  Check 'fixture has exactly one usage event to mutate' $counts.Count 1
  $counts[0].l = @(20, 4, 2, 1, 22); $counts[0].t = @(20, 4, 2, 1, 22)
  $counts[0].PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new('body', $bodySentinel))
  Write-Json $cachePath $cache
  Check 'cache mutation leaves the source signature unchanged' ('{0}|{1}' -f (Get-Item -LiteralPath $sourcePath).Length, (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc.Ticks) $sourceSignature
  $null = Run '04-valid-cache-change-rebinds-history' $case 22 0 1 0
  $history = History-State $output
  Check 'valid cache change selects a new history blob' ($history.entry.hash -cne $oldHash) $true
  Check 'valid cache change updates its proof' ($history.entry.cacheProof -cne $oldProof) $true
  Check 'old committed immutable content remains intact' (Text-Hash ([IO.File]::ReadAllText($oldBlob))) $oldHash
  Move-TestFile $sourcePath $parked
  $null = Run '05-cache-change-survives-source-migration' $case 22 0 0 0 -Retained 1

  Move-TestFile $parked $sourcePath
  # The missing-source run committed an empty current-source cache manifest.
  # Restoring the original source must therefore reparse its authoritative 11
  # tokens before testing the now-warm history repair branches below.
  $null = Run '06-restored-source-replaces-retained-cache-version' $case 11 0 0 1
  $history = History-State $output
  Check 'delete repair begins with a proof' ($history.entry.cacheProof -match '^[a-f0-9]{64}$') $true
  Remove-TestFile $history.blobPath
  $null = Run '07-proven-history-missing-source-repairs' $case 11 0 1 0
  $history = History-State $output
  Check 'missing proven history is repaired' (Text-Hash ([IO.File]::ReadAllText($history.blobPath))) $history.entry.hash
  Write-Text $history.blobPath '{broken-history'
  $null = Run '08-proven-history-corrupt-source-repairs' $case 11 0 1 0
  $history = History-State $output
  $validBlobText = [IO.File]::ReadAllText($history.blobPath)
  Check 'corrupt proven history is repaired' (Text-Hash $validBlobText) $history.entry.hash

  Move-TestFile $sourcePath $parked
  Write-Text $history.blobPath '{broken-history'
  $null = Run '09-proven-corrupt-history-source-absent-rejected' $case 0 0 0 0 -ExpectFailure
  Write-Text $history.blobPath $validBlobText
  Remove-TestFile $history.blobPath
  $null = Run '10-proven-missing-history-source-absent-rejected' $case 0 0 0 0 -ExpectFailure
  Write-Text $history.blobPath $validBlobText
  $null = Run '11-valid-history-restored-without-source' $case 11 0 0 0 -Retained 1
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
