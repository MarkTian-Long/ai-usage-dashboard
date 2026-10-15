# Bounded synthetic append/cold equivalence against an explicit frozen baseline.
# No production logs/services; every mutation is under a new short test directory.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BaselineGenerator,
  [string]$Generator = '',
  [string]$ExpectedBaselineSha256 = '',
  [string]$ExpectedGeneratorSha256 = '',
  [string]$TestOutputRoot = '',
  [switch]$EncodingBoundariesOnly
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
if (-not $TestOutputRoot) { $TestOutputRoot = Join-Path ([IO.Path]::GetTempPath()) 'uappend-tests' }
$baselinePath = (Resolve-Path -LiteralPath $BaselineGenerator).Path
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
if ([StringComparer]::OrdinalIgnoreCase.Equals($baselinePath, $generatorPath)) { throw 'The baseline must be a separate frozen generator.' }
$baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
$generatorHash = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedBaselineSha256 -and $baselineHash -ne $ExpectedBaselineSha256) { throw 'The fixed baseline SHA256 differs.' }
if ($ExpectedGeneratorSha256 -and $generatorHash -ne $ExpectedGeneratorSha256) { throw 'The fixed candidate SHA256 differs.' }
$engine = (Get-Process -Id $PID).Path
$outputBase = [IO.Path]::GetFullPath($TestOutputRoot)
do { $runRoot = [IO.Path]::GetFullPath((Join-Path $outputBase ('r' + [Guid]::NewGuid().ToString('N').Substring(0, 4)))) }
while (Test-Path -LiteralPath $runRoot)
if (-not $runRoot.StartsWith(($outputBase.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test output path.' }
New-Item -ItemType Directory -Path $runRoot | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$mutex = 'Local\AppendRefreshTest_' + [Guid]::NewGuid().ToString('N')
$checks = 0
$scenarios = [Collections.Generic.List[object]]::new()
$failure = $null

function Check([string]$Name, $Actual, $Expected) {
  $equal = if ($null -eq $Expected) { $null -eq $Actual } else { $Actual -ceq $Expected }
  if (-not $equal) { throw "$Name expected [$Expected], got [$Actual]" }
  $script:checks++
}
function Bound([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith(($script:runRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fixture mutation outside the new test run directory.'
  }
  $resolved
}
function Json($Value) { ConvertTo-Json -InputObject $Value -Depth 24 -Compress }
function Read-Json([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Write-Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText((Bound $Path), $Text, $script:utf8) }
function Write-Json([string]$Path, $Value) { Write-Text $Path (Json $Value) }
function Text-Hash([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { ([BitConverter]::ToString($sha.ComputeHash($script:utf8.GetBytes($Text))).Replace('-', '')).ToLowerInvariant() }
  finally { $sha.Dispose() }
}
function Write-Source([string]$Path, [string[]]$Lines, [string]$NewLine = "`n", [switch]$NoFinalNewLine, [Text.Encoding]$Encoding = $script:utf8) {
  $text = $Lines -join $NewLine
  if (-not $NoFinalNewLine) { $text += $NewLine }
  $body = $Encoding.GetBytes($text); $preamble = $Encoding.GetPreamble()
  $bytes = [byte[]]::new($preamble.Length + $body.Length)
  [Buffer]::BlockCopy($preamble, 0, $bytes, 0, $preamble.Length)
  [Buffer]::BlockCopy($body, 0, $bytes, $preamble.Length, $body.Length)
  [IO.File]::WriteAllBytes((Bound $Path), $bytes)
}
function Append-Text([string]$Path, [string]$Text, [Text.Encoding]$Encoding = $script:utf8) {
  $stream = [IO.File]::Open((Bound $Path), [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try { $bytes = $Encoding.GetBytes($Text); $stream.Write($bytes, 0, $bytes.Length) }
  finally { $stream.Dispose() }
}
function Append-Events([string]$Path, [object[]]$Events, [string]$NewLine = "`n", [Text.Encoding]$Encoding = $script:utf8) {
  $lines = @($Events | ForEach-Object { Json $_ })
  Append-Text $Path (($lines -join $NewLine) + $NewLine) $Encoding
}
function Move-Fixture([string]$From, [string]$To) { Move-Item -LiteralPath (Bound $From) -Destination (Bound $To) }
function New-Case([string]$Name) {
  $root = Bound (Join-Path $script:runRoot $Name)
  $case = [pscustomobject]@{ root = $root; source = (Join-Path $root 's'); baseline = (Join-Path $root 'b'); candidate = (Join-Path $root 'c') }
  foreach ($path in @((Join-Path $case.source 'sessions'), (Join-Path $case.source 'archived_sessions'), $case.baseline, $case.candidate)) {
    New-Item -ItemType Directory -Path (Bound $path) -Force | Out-Null
  }
  $case
}
function Source-Path($Case, [string]$Name = 'a') { Join-Path $Case.source ('sessions\' + $Name + '.jsonl') }
function Event([string]$At, [string]$Type, $Payload) { [ordered]@{ timestamp = $At; type = $Type; payload = $Payload } }
function Meta([string]$Id, [string]$Role = '') {
  $payload = [ordered]@{ id = $Id; session_id = 'append-parent' }
  if ($Role) { $payload.parent_thread_id = 'append-parent'; $payload.source = @{ subagent = @{ other = $Role } } }
  Event '2026-10-14T15:50:00Z' 'session_meta' $payload
}
function Context([string]$Turn = 'append-turn', [string]$Model = 'fixture-model-a', [string]$Effort = 'high') {
  Event '2026-10-14T15:50:01Z' 'turn_context' @{ turn_id = $Turn; model = $Model; effort = $Effort }
}
function Vector([long]$InputTokens, [long]$OutputTokens, [long]$Cached = 0) {
  [ordered]@{ input_tokens = $InputTokens; cached_input_tokens = $Cached; output_tokens = $OutputTokens; reasoning_output_tokens = 0; total_tokens = $InputTokens + $OutputTokens }
}
function Token([string]$At, $Last, $Cumulative, [string]$Turn = 'append-turn') {
  $payload = @{ type = 'token_count'; info = @{ last_token_usage = $Last; total_token_usage = $Cumulative } }
  if ($Turn) { $payload.turn_id = $Turn }
  Event $At 'event_msg' $payload
}
function Record([string]$At, [string]$Response, $Last, $Cumulative, [string]$Turn = 'append-turn') {
  Event $At 'token_usage_record' @{ response_id = $Response; turn_id = $Turn; usage = $Last; thread_token_usage = $Cumulative }
}
function Body([string]$Text = 'SYNTHETIC_APPEND_BODY_SENTINEL') {
  Event '2026-10-14T15:50:02Z' 'response_item' @{ type = 'message'; role = 'user'; content = @(@{ type = 'input_text'; text = $Text }) }
}
function Prefix([string]$Id, [object[]]$Tail) {
  Json (Meta $Id); Json (Context)
  # Enough harmless prefix bytes to make a real append hit measurable, while
  # keeping each fixture small. Include blank/malformed lines in physical i.
  for ($index = 0; $index -lt 48; $index++) { Json (Body ('SYNTHETIC_APPEND_BODY_SENTINEL ' + ('x' * 240))) }
  ''; '{malformed-synthetic-line'
  foreach ($item in $Tail) { Json $item }
}
function Literal([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

# Public table order is unspecified. Preserve all scalar fields/session aliases,
# but retain the exact order of cached events and their physical source i values.
function Canonical($Value, [bool]$PreserveOrder = $false) {
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [string] -or $Value -is [ValueType]) { return (Json $Value) }
  if ($Value -is [Collections.IDictionary] -or $Value -is [Management.Automation.PSCustomObject]) {
    $names = [Collections.Generic.List[string]]::new()
    if ($Value -is [Collections.IDictionary]) { foreach ($key in $Value.Keys) { $names.Add([string]$key) } }
    else { foreach ($property in $Value.PSObject.Properties) { $names.Add($property.Name) } }
    $names.Sort([StringComparer]::Ordinal)
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
      $child = if ($Value -is [Collections.IDictionary]) { $Value[$name] } else { $Value.PSObject.Properties[$name].Value }
      $parts.Add((Json $name) + ':' + (Canonical $child $PreserveOrder))
    }
    return '{' + ($parts -join ',') + '}'
  }
  if ($Value -is [Collections.IEnumerable]) {
    $items = [Collections.Generic.List[string]]::new()
    foreach ($child in $Value) { $items.Add((Canonical $child $PreserveOrder)) }
    if (-not $PreserveOrder) { $items.Sort([StringComparer]::Ordinal) }
    return '[' + ($items -join ',') + ']'
  }
  throw ('Unsupported core data type: ' + $Value.GetType().FullName)
}
function Core([string]$Output) {
  $data = Read-Json (Join-Path $Output 'codex-usage-dashboard-data.json')
  $core = [ordered]@{}
  foreach ($property in $data.PSObject.Properties) { if ($property.Name -notin @('generated', 'refresh')) { $core[$property.Name] = $property.Value } }
  Canonical $core
}
function History-State([string]$Output) {
  $namespaces = @(Get-ChildItem -LiteralPath (Join-Path $Output '.codex-usage-dashboard-history') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') })
  Check 'one fixture history namespace' $namespaces.Count 1
  $path = Join-Path $namespaces[0].FullName 'manifest.json'
  [pscustomobject]@{ root = $namespaces[0].FullName; path = $path; manifest = (Read-Json $path) }
}
function Invoke-One([string]$Name, [string]$Path, [string]$Hash, $Case, [string]$Output, [switch]$ExpectFailure) {
  Check "$Name fixed generator SHA" (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash $Hash
  $before = @{}
  if ($ExpectFailure) {
    foreach ($artifact in @((Join-Path $Output 'codex-usage-dashboard-data.json'), (Join-Path $Output 'codex-usage-dashboard.html'), (History-State $Output).path)) {
      $before[$artifact] = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
    }
  }
  $command = '& ' + (Literal $Path) + ' -SourceRoot ' + (Literal $Case.source) + ' -OutputRoot ' + (Literal $Output) +
    ' -MutexName ' + (Literal $script:mutex) + ' -AsOfDate 2026-10-15'
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $messages = @(& $script:engine -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1); $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $saved }
  $messages | Out-File -LiteralPath (Bound (Join-Path $script:runRoot ($Name + '.log'))) -Encoding UTF8
  if ($ExpectFailure) {
    Check "$Name rejects damaged committed history" ($code -ne 0) $true
    foreach ($artifact in $before.Keys) { Check "$Name previous artifact remains unchanged" (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash $before[$artifact] }
    return
  }
  if ($code -ne 0) { throw ("$Name generator failed: " + ($messages -join [Environment]::NewLine)) }
  Check "$Name generator exit" $code 0
}
function Compare-Extraction($Case, [string]$Name) {
  $beforeManifest = Read-Json (Join-Path $Case.baseline '.codex-usage-dashboard-cache\manifest.json')
  $afterManifest = Read-Json (Join-Path $Case.candidate '.codex-usage-dashboard-cache\manifest.json')
  Check "$Name same current file count" @($afterManifest.files).Count @($beforeManifest.files).Count
  foreach ($entry in @($beforeManifest.files)) {
    $other = @($afterManifest.files | Where-Object key -eq $entry.key)
    Check "$Name same physical source path hash" $other.Count 1
    $before = Read-Json (Join-Path $Case.baseline ('.codex-usage-dashboard-cache\' + $entry.key + '.json'))
    $after = Read-Json (Join-Path $Case.candidate ('.codex-usage-dashboard-cache\' + $entry.key + '.json'))
    Check "$Name exact ordered extracted events and physical lines" (Canonical @($after.events) $true) (Canonical @($before.events) $true)
  }
}
function Check-AppendCounters($Data, [int]$Minimum, [int]$Maximum, [string]$Name) {
  foreach ($field in @('appended', 'appendBytesParsed', 'prefixBytesVerified', 'parsedBytes')) {
    $property = $Data.refresh.PSObject.Properties[$field]
    Check "$Name exposes $field" ($null -ne $property) $true
    $value = $property.Value
    Check "$Name nonnegative integer $field" ($value -is [ValueType] -and $value -isnot [bool] -and [double]$value -ge 0 -and [Math]::Floor([double]$value) -eq [double]$value) $true
  }
  Check "$Name expected append hit range" ($Data.refresh.appended -ge $Minimum -and $Data.refresh.appended -le $Maximum) $true
  if ($Minimum -gt 0) {
    Check "$Name actually parses appended bytes" ($Data.refresh.appendBytesParsed -gt 0) $true
    Check "$Name verifies the old prefix" ($Data.refresh.prefixBytesVerified -gt 0) $true
  }
}
function Check-NoAppendState([string]$Output, [string[]]$Paths, [string]$Name) {
  $cacheRoot = Join-Path $Output '.codex-usage-dashboard-cache'
  $manifest = Read-Json (Join-Path $cacheRoot 'manifest.json')
  foreach ($path in $Paths) {
    $key = Text-Hash ((Get-Item -LiteralPath $path).FullName)
    $entry = @($manifest.files | Where-Object key -eq $key)
    Check "$Name identifies source before checking its checkpoint" $entry.Count 1
    Check "$Name writes no checkpoint" (Test-Path -LiteralPath (Join-Path $cacheRoot ($key + '.append.json'))) $false
  }
}
function Seed($Case, [string]$Name, [switch]$BaselineAlso) {
  Invoke-One ($Name + '-seed-candidate') $script:generatorPath $script:generatorHash $Case $Case.candidate
  $data = Read-Json (Join-Path $Case.candidate 'codex-usage-dashboard-data.json')
  Check-AppendCounters $data 0 0 ($Name + '-cold')
  if ($BaselineAlso) { Invoke-One ($Name + '-seed-baseline') $script:baselinePath $script:baselineHash $Case $Case.baseline }
}
function Pair([string]$Name, $Case, [int]$Minimum = 0, [int]$Maximum = 0) {
  $sourceHashes = @(Get-ChildItem -LiteralPath $Case.source -Recurse -File -Filter '*.jsonl' | ForEach-Object {
    @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  })
  Invoke-One ($Name + '-baseline') $script:baselinePath $script:baselineHash $Case $Case.baseline
  Invoke-One ($Name + '-candidate') $script:generatorPath $script:generatorHash $Case $Case.candidate
  $before = Core $Case.baseline; $after = Core $Case.candidate
  if ($after -cne $before) {
    Write-Text (Join-Path $script:runRoot ($Name + '.baseline-core.json')) $before
    Write-Text (Join-Path $script:runRoot ($Name + '.candidate-core.json')) $after
  }
  Check "$Name complete core including session aliases" ($after -ceq $before) $true
  Compare-Extraction $Case $Name
  $data = Read-Json (Join-Path $Case.candidate 'codex-usage-dashboard-data.json')
  Check-AppendCounters $data $Minimum $Maximum $Name
  foreach ($item in $sourceHashes) { Check "$Name synthetic source unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash }
  $script:scenarios.Add([ordered]@{ name = $Name; passed = $true; appended = $data.refresh.appended; appendBytesParsed = $data.refresh.appendBytesParsed; parsedBytes = $data.refresh.parsedBytes })
  $data
}

try {
  $one = Vector 10 1 2; $two = Vector 20 2 4; $sum = Vector 30 3 6; $zero = Vector 0 0
  $first = Token '2026-10-14T15:59:59Z' $one $one
  $next = Token '2026-10-14T16:00:01Z' $two $sum

  $a = New-Case '1'; $path = Source-Path $a
  Write-Source $path @(Prefix 'append-normal' @($first))
  Seed $a '01-normal'
  $oldLength = (Get-Item -LiteralPath $path).Length
  Append-Events $path @($next)
  $data = Pair '01-normal-append' $a 1 1
  Check 'normal append parses less than the entire source' ($data.refresh.parsedBytes -lt (Get-Item -LiteralPath $path).Length) $true
  Check 'normal append verifies the full original prefix' ($data.refresh.prefixBytesVerified -ge $oldLength) $true
  $cold = Bound (Join-Path $a.root 'd'); New-Item -ItemType Directory -Path $cold | Out-Null
  Invoke-One '01-normal-candidate-cold' $generatorPath $generatorHash $a $cold
  Check 'appended result equals a separate candidate cold read' (Core $cold) (Core $a.candidate)

  if (-not $EncodingBoundariesOnly) {
  $b = New-Case '2'; $path = Source-Path $b
  Write-Source $path @(Prefix 'append-pending' @((Record '2026-10-14T15:59:57Z' 'append-response-a' $one $one)))
  Seed $b '02-pending'
  Append-Events $path @(
    (Token '2026-10-14T15:59:59Z' $one $one),
    (Event '2026-10-14T16:00:00Z' 'event_msg' @{ type = 'compacted'; window_id = 'append-reset' }),
    (Token '2026-10-14T16:00:01Z' $zero $zero),
    (Record '2026-10-14T16:00:02Z' 'append-response-b' $one $one)
  )
  $data = Pair '02-pending-and-equal-usage-reset' $b 1 1
  Check 'only the distinct response is supplemental' $data.refresh.supplementalTokenRequests 1

  $c = New-Case '3'; $path = Source-Path $c
  Write-Source $path @(Prefix 'append-context' @(
    (Event '2026-10-14T15:59:56Z' 'event_msg' @{ type = 'task_started'; turn_id = 'append-turn' }),
    (Event '2026-10-14T15:59:57Z' 'event_msg' @{ type = 'thread_settings_applied'; thread_settings = @{ model = 'fixture-setting'; reasoning_effort = 'medium' } })
  ))
  Seed $c '03-context'
  Append-Events $path @(
    (Token '2026-10-14T15:59:59Z' $one $one ''),
    (Event '2026-10-14T16:00:00Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'append-turn'; duration_ms = 1250; time_to_first_token_ms = 0 }),
    (Context 'append-next' 'fixture-next' 'low'),
    (Token '2026-10-14T16:00:02Z' $two $sum '')
  )
  $null = Pair '03-task-context-and-settings-boundaries' $c 1 1

  $d = New-Case '4'
  $skillRoot = Bound (Join-Path $d.source 'skills\append-fixture'); New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
  $skillPath = Join-Path $skillRoot 'SKILL.md'
  Write-Text $skillPath "---`nname: append-fixture`ndescription: Synthetic append fixture.`n---`nBody.`n"
  $call = Event '2026-10-14T15:59:58Z' 'response_item' @{ type = 'function_call'; name = 'exec_command'; arguments = (Json @{ cmd = "Get-Content -LiteralPath '$skillPath'" }) }
  $roles = @('', 'guardian', 'worker')
  for ($index = 0; $index -lt $roles.Count; $index++) { Write-Source (Source-Path $d ([string]$index)) @(Prefix ('append-meta-' + $index) @($call, $first)) }
  Seed $d '04-late-meta'
  for ($index = 0; $index -lt $roles.Count; $index++) {
    Append-Events (Source-Path $d ([string]$index)) @((Meta ('append-meta-' + $index) $roles[$index]), (Context), $next)
  }
  $null = Pair '04-late-meta-guardian-and-subagent-fallback' $d

  $e = New-Case '5'
  $unicode = [string][char]0x4E2D + [char]0x6587 + [char]0xD83D + [char]0xDE80
  $crlf = "`r`n"
  $pathA = Source-Path $e 'a'; $pathB = Source-Path $e 'b'; $pathC = Source-Path $e 'c'
  Write-Source $pathA @(Prefix 'append-crlf' @($first, (Body $unicode))) $crlf
  $partial = Json $first
  Write-Source $pathB (@(Prefix 'append-partial' @()) + @($partial.Substring(0, $partial.Length - 1))) $crlf -NoFinalNewLine
  Write-Source $pathC @(Prefix 'append-no-newline' @($first)) $crlf -NoFinalNewLine
  Seed $e '05-newlines'
  Append-Events $pathA @((Body $unicode), $next) $crlf
  Append-Text $pathB ('}' + $crlf + (Json $next) + $crlf)
  Append-Text $pathC ($crlf + (Json $next) + $crlf)
  $null = Pair '05-crlf-utf8-and-unfinished-last-line' $e 1 3

  $f = New-Case '6'; $path = Source-Path $f
  $short = @(Prefix 'append-truncated' @($first))
  Write-Source $path ($short + @((Json $next)))
  Seed $f '06-truncate'
  Write-Source $path $short
  $null = Pair '06-truncated-source-fallback' $f

  $g = New-Case '7'; $path = Source-Path $g
  Write-Source $path @(Prefix 'append-rewrite' @($first))
  Seed $g '07-same-length'
  $before = [IO.File]::ReadAllText($path); $length = (Get-Item -LiteralPath $path).Length
  Write-Text $path ($before.Replace('fixture-model-a', 'fixture-model-b'))
  [IO.File]::SetLastWriteTimeUtc((Bound $path), [DateTime]::UtcNow.AddSeconds(2))
  Check 'same-length rewrite fixture retains byte length' (Get-Item -LiteralPath $path).Length $length
  $null = Pair '07-same-length-rewrite-fallback' $g

  $h = New-Case '8'; $path = Source-Path $h
  Write-Source $path @(Prefix 'append-prefix-change' @($first))
  Seed $h '08-prefix-change'
  $before = [IO.File]::ReadAllText($path)
  Write-Text $path ($before.Replace('fixture-model-a', 'fixture-model-b'))
  Append-Events $path @($next)
  $null = Pair '08-growth-with-rewritten-prefix-fallback' $h

  $j = New-Case '9'
  foreach ($name in @('missing', 'corrupt', 'tampered')) { Write-Source (Source-Path $j $name) @(Prefix ('append-state-' + $name) @($first)) }
  Seed $j '09-states'
  $cacheRoot = Join-Path $j.candidate '.codex-usage-dashboard-cache'
  $index = Read-Json (Join-Path $cacheRoot 'manifest.json')
  Check 'state fixture has three current files' @($index.files).Count 3
  $states = @()
  foreach ($entry in @($index.files)) {
    $statePath = Join-Path $cacheRoot ($entry.key + '.append.json')
    Check 'cold read saves an append checkpoint' (Test-Path -LiteralPath $statePath) $true
    $state = Read-Json $statePath
    Check 'checkpoint envelope schema' $state.schema 1
    Check 'checkpoint has protected structural state' ($state.protectedState -is [string] -and $state.protectedState.Length -gt 0) $true
    $states += [pscustomobject]@{ path = $statePath; envelope = $state }
  }
  $offset = 0
  foreach ($state in $states) {
    if ($offset -eq 0) { Remove-Item -LiteralPath (Bound $state.path) -Force }
    elseif ($offset -eq 1) { Write-Text $state.path '{invalid-checkpoint' }
    else { Write-Json $state.path $states[0].envelope }
    $offset++
  }
  foreach ($name in @('missing', 'corrupt', 'tampered')) { Append-Events (Source-Path $j $name) @($next) }
  $null = Pair '09-missing-corrupt-and-tampered-state-fallback' $j

  $k = New-Case 'a'; $badPath = Source-Path $k 'bad'; $widePath = Source-Path $k 'wide'
  $badLines = @(Prefix 'append-bad-utf8' @((Body 'BAD_UTF8_MARKER'), $first))
  $badText = ($badLines -join "`n") + "`n"; $badBytes = $utf8.GetBytes($badText)
  $badOffset = $utf8.GetByteCount($badText.Substring(0, $badText.IndexOf('BAD_UTF8_MARKER', [StringComparison]::Ordinal)))
  $badBytes[$badOffset] = 255
  [IO.File]::WriteAllBytes((Bound $badPath), $badBytes)
  $wideEncoding = [Text.UnicodeEncoding]::new($false, $true)
  Write-Source $widePath @(Prefix 'append-utf16' @($first)) "`r`n" -Encoding $wideEncoding
  Seed $k '10-encoding'
  Append-Events $badPath @($next)
  Append-Events $widePath @($next) "`r`n" $wideEncoding
  $null = Pair '10-invalid-utf8-and-utf16-fallback' $k

  $m = New-Case 'b'; $pathA = Source-Path $m 'a'; $pathB = Source-Path $m 'b'
  Write-Source $pathA @(Prefix 'append-atomic-a' @($first))
  Write-Source $pathB @(Prefix 'append-atomic-b' @($first))
  Seed $m '11-atomic' -BaselineAlso
  $saved = @()
  $bSourceKey = Text-Hash ((Get-Item -LiteralPath $pathB).FullName)
  foreach ($output in @($m.baseline, $m.candidate)) {
    $history = History-State $output
    $sourceCache = Read-Json (Join-Path $output '.codex-usage-dashboard-cache\manifest.json')
    $bKey = @($sourceCache.files | Where-Object key -eq $bSourceKey)
    Check 'atomic fixture identifies the second source' $bKey.Count 1
    $bEntry = @($history.manifest.files | Where-Object key -eq $bKey[0].key)[0]
    $blob = Join-Path $history.root ($bEntry.hash + '.json')
    $saved += [pscustomobject]@{ path = $blob; text = [IO.File]::ReadAllText($blob) }
    Write-Text $blob '{broken-history'
  }
  Move-Fixture $pathB (Join-Path $m.root 'v')
  Append-Events $pathA @($next)
  Invoke-One '11-atomic-failure-baseline' $baselinePath $baselineHash $m $m.baseline -ExpectFailure
  Invoke-One '11-atomic-failure-candidate' $generatorPath $generatorHash $m $m.candidate -ExpectFailure
  Move-Fixture $pathA (Join-Path $m.root 'u')
  foreach ($item in $saved) { Write-Text $item.path $item.text }
  $null = Pair '11-failed-append-preserves-committed-history' $m
  }

  $n = New-Case 'c'
  $nulPath = Source-Path $n 'raw'; $widePath = Source-Path $n 'wide'; $quadPath = Source-Path $n 'quad'
  $nulLine = '{"type":"synthetic_bad_line","value":"x' + [char]0 + 'y"}'
  Write-Source $nulPath (@(Prefix 'append-raw-nul' @()) + @($nulLine, (Json $first)))
  $wideNoBom = [Text.UnicodeEncoding]::new($false, $false)
  $quadNoBom = [Text.UTF32Encoding]::new($false, $false)
  Write-Source $widePath @(Prefix 'append-utf16-no-bom' @($first)) -Encoding $wideNoBom
  Write-Source $quadPath @(Prefix 'append-utf32-no-bom' @($first)) -Encoding $quadNoBom
  Seed $n '12-nul-wide-no-bom'
  Check-NoAppendState $n.candidate @($nulPath, $widePath, $quadPath) 'NUL or wide source cold read'
  Append-Events $nulPath @($next)
  Append-Events $widePath @($next) -Encoding $wideNoBom
  Append-Events $quadPath @($next) -Encoding $quadNoBom
  $null = Pair '12-raw-nul-and-wide-no-bom-fallback' $n
  Check-NoAppendState $n.candidate @($nulPath, $widePath, $quadPath) 'NUL or wide source append'

  Check 'baseline remains fixed at completion' (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash $baselineHash
  Check 'candidate remains fixed at completion' (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
} catch { $failure = $_ }
$result = [ordered]@{ passed = ($null -eq $failure); assertions = $checks; scenarios = $scenarios.Count; engine = $PSVersionTable.PSVersion.ToString(); baselineSha256 = $baselineHash; generatorSha256 = $generatorHash; runRoot = $runRoot; cases = @($scenarios) }
if ($failure) { $result.failure = [string]$failure }
Write-Text (Join-Path $runRoot 'result.json') (Json $result)
$result | ConvertTo-Json -Depth 6 -Compress
if ($failure) { throw $failure }
