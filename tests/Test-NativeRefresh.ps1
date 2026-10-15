# Small, synthetic baseline/candidate equivalence tests for the native fast path.
# The baseline must be explicit and must have its frozen web sources beside it.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BaselineGenerator,
  [string]$Generator = '',
  [string]$ExpectedBaselineSha256 = '',
  [string]$ExpectedGeneratorSha256 = '',
  [string]$TestOutputRoot = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Generator) { $Generator = Join-Path $PSScriptRoot '..\refresh-ai-usage-dashboard.ps1' }
if (-not $TestOutputRoot) { $TestOutputRoot = Join-Path $PSScriptRoot 'service-fixtures\native-refresh' }
$baselinePath = (Resolve-Path -LiteralPath $BaselineGenerator).Path
$generatorPath = (Resolve-Path -LiteralPath $Generator).Path
if ([StringComparer]::OrdinalIgnoreCase.Equals($baselinePath, $generatorPath)) { throw 'The baseline must be a separate frozen generator.' }
$baselineHash = (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash
$generatorHash = (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash
if ($ExpectedBaselineSha256 -and $baselineHash -ne $ExpectedBaselineSha256) { throw 'The fixed baseline SHA256 differs.' }
if ($ExpectedGeneratorSha256 -and $generatorHash -ne $ExpectedGeneratorSha256) { throw 'The fixed candidate SHA256 differs.' }
$engine = (Get-Process -Id $PID).Path
$base = [IO.Path]::GetFullPath($TestOutputRoot)
do { $runRoot = [IO.Path]::GetFullPath((Join-Path $base ('r' + [Guid]::NewGuid().ToString('N').Substring(0, 4)))) }
while (Test-Path -LiteralPath $runRoot)
if (-not $runRoot.StartsWith(($base.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test output path.' }
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$checks = 0
$scenarios = [Collections.Generic.List[object]]::new()
$failure = $null
$mutex = 'Local\NativeRefreshTest_' + [Guid]::NewGuid().ToString('N')

function Check([string]$Name, $Actual, $Expected) {
  if ($Actual -cne $Expected) { throw "$Name expected [$Expected], got [$Actual]" }
  $script:checks++
}
function Test-PathBound([string]$Path) {
  $resolved = [IO.Path]::GetFullPath($Path)
  if (-not $resolved.StartsWith(($script:runRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture write outside the run root.' }
  $resolved
}
function Json($Value) { ConvertTo-Json -InputObject $Value -Depth 24 -Compress }
function Read-Json([string]$Path) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) }
function Write-Text([string]$Path, [string]$Text) {
  [IO.File]::WriteAllText((Test-PathBound $Path), $Text, [Text.UTF8Encoding]::new($false))
}
function Write-Lines([string]$Path, [string[]]$Lines) {
  [IO.File]::WriteAllLines((Test-PathBound $Path), $Lines, [Text.UTF8Encoding]::new($false))
}
function New-Case([string]$Name) {
  $root = Join-Path $script:runRoot $Name
  $source = Join-Path $root 's'
  $baseline = Join-Path $root 'b'
  $candidate = Join-Path $root 'c'
  $sessions = Join-Path $source 'sessions'
  $archives = Join-Path $source 'archived_sessions'
  New-Item -ItemType Directory -Path $sessions, $archives, $baseline, $candidate -Force | Out-Null
  [pscustomobject]@{ root = $root; source = $source; baseline = $baseline; candidate = $candidate; sessions = $sessions; archives = $archives }
}
function Event([string]$At, [string]$Type, $Payload) { [ordered]@{ timestamp = $At; type = $Type; payload = $Payload } }
function Meta([string]$Id, [string]$Role = '') {
  $payload = [ordered]@{ id = $Id; session_id = 'native-parent' }
  if ($Role) { $payload.parent_thread_id = 'native-parent'; $payload.source = @{ subagent = @{ other = $Role } } }
  Event '2026-10-14T15:50:00Z' 'session_meta' $payload
}
function Context([string]$Id, [string]$Model = 'fixture-native', [string]$At = '2026-10-14T15:50:01Z') {
  Event $At 'turn_context' @{ turn_id = $Id; model = $Model; effort = 'high' }
}
function Vector([long]$InputTokens, [long]$OutputTokens, [long]$Cached = 0) {
  [ordered]@{ input_tokens = $InputTokens; cached_input_tokens = $Cached; output_tokens = $OutputTokens; reasoning_output_tokens = 0; total_tokens = $InputTokens + $OutputTokens }
}
function Token([string]$At, $Last, $Cumulative, [string]$Turn = 'native-turn') {
  Event $At 'event_msg' @{ type = 'token_count'; turn_id = $Turn; info = @{ last_token_usage = $Last; total_token_usage = $Cumulative } }
}
function Record([string]$At, [string]$Response, $Last, $Cumulative, [string]$Turn = 'native-turn') {
  Event $At 'token_usage_record' @{ response_id = $Response; turn_id = $Turn; usage = $Last; thread_token_usage = $Cumulative }
}
function Literal([string]$Text) { "'" + $Text.Replace("'", "''") + "'" }

# Array order in public tables is unspecified; compare row multisets while
# retaining every field, every value, and the original numeric session aliases.
# Event arrays and vectors use PreserveOrder so source ordering is also checked.
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
  foreach ($property in $data.PSObject.Properties) {
    if ($property.Name -notin @('generated', 'refresh')) { $core[$property.Name] = $property.Value }
  }
  Canonical $core
}
function Invoke-One([string]$Name, [string]$Path, [string]$Hash, [string]$Source, [string]$Output, [string]$Culture = '') {
  Check "$Name fixed source SHA" (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash $Hash
  $command = ''
  if ($Culture) { $command += '[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo(' + (Literal $Culture) + ');' }
  $command += '& ' + (Literal $Path) + ' -SourceRoot ' + (Literal $Source) + ' -OutputRoot ' + (Literal $Output) + ' -MutexName ' + (Literal $script:mutex) + ' -AsOfDate 2026-10-15'
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $messages = @(& $script:engine -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1); $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $saved }
  $messages | Out-File -LiteralPath (Join-Path $script:runRoot ($Name + '.log')) -Encoding UTF8
  if ($code -ne 0) { throw ("$Name generator failed: " + ($messages -join [Environment]::NewLine)) }
  Check "$Name generator exit" $code 0
}
function Compare-Extraction($Case, [string]$Name) {
  $beforeManifest = Read-Json (Join-Path $Case.baseline '.codex-usage-dashboard-cache\manifest.json')
  $afterManifest = Read-Json (Join-Path $Case.candidate '.codex-usage-dashboard-cache\manifest.json')
  Check "$Name same current source file count" @($afterManifest.files).Count @($beforeManifest.files).Count
  foreach ($entry in @($beforeManifest.files)) {
    $other = @($afterManifest.files | Where-Object key -eq $entry.key)
    Check "$Name same source path hash" $other.Count 1
    $before = Read-Json (Join-Path $Case.baseline ('.codex-usage-dashboard-cache\' + $entry.key + '.json'))
    $after = Read-Json (Join-Path $Case.candidate ('.codex-usage-dashboard-cache\' + $entry.key + '.json'))
    Check "$Name preserves event fields, physical line numbers, and source order" (Canonical @($after.events) $true) (Canonical @($before.events) $true)
  }
}
function Pair([string]$Name, $Case, [string]$Culture = '', [switch]$CompareEvents) {
  $sourceHashes = @(Get-ChildItem -LiteralPath $Case.source -Recurse -File -Filter '*.jsonl' | ForEach-Object {
    @{ path = $_.FullName; hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  })
  Invoke-One ($Name + '-baseline') $script:baselinePath $script:baselineHash $Case.source $Case.baseline $Culture
  Invoke-One ($Name + '-candidate') $script:generatorPath $script:generatorHash $Case.source $Case.candidate $Culture
  $before = Core $Case.baseline
  $after = Core $Case.candidate
  Write-Text (Join-Path $script:runRoot ($Name + '.baseline-core.json')) $before
  Write-Text (Join-Path $script:runRoot ($Name + '.candidate-core.json')) $after
  Check "$Name normalized complete core data (see saved core JSON on failure)" ($after -ceq $before) $true
  if ($CompareEvents) { Compare-Extraction $Case $Name }
  foreach ($item in $sourceHashes) { Check "$Name original synthetic log unchanged" (Get-FileHash -LiteralPath $item.path -Algorithm SHA256).Hash $item.hash }
  $script:scenarios.Add([ordered]@{ name = $Name; passed = $true; culture = $Culture })
}
function Patch-Cache($Case, [string[]]$Events) {
  foreach ($output in @($Case.baseline, $Case.candidate)) {
    $manifest = Read-Json (Join-Path $output '.codex-usage-dashboard-cache\manifest.json')
    Check 'cache mutation targets one synthetic file' @($manifest.files).Count 1
    $path = Join-Path $output ('.codex-usage-dashboard-cache\' + $manifest.files[0].key + '.json')
    $cache = Read-Json $path
    $text = '{"version":7,"parser":' + (Json $cache.parser) + ',"source":' + (Json $cache.source) + ',"events":[' + ($Events -join ',') + ']}'
    Write-Text $path $text
  }
}
function Cached-Count([int]$Line, [string]$Last, [string]$Cumulative, [string]$Model = '"fixture-number"') {
  '{"s":"native-numeric","a":"2026-10-14T16:00:' + $Line.ToString('00') + '.0000000+00:00","i":' + $Line + ',"k":"token_count","mo":' + $Model + ',"ef":"high","sc":"task","l":' + $Last + ',"t":' + $Cumulative + ',"ignored":"PRIVATE_NATIVE_BODY_SENTINEL"}'
}

try {
  # The source prefilter must inspect only actual root/payload type properties,
  # honor JSON escapes/property order, and retain every physical line offset.
  $a = New-Case '1'
  $skillRoot = Join-Path $a.source 'skills\native-fixture'
  New-Item -ItemType Directory -Path $skillRoot -Force | Out-Null
  $skillPath = Join-Path $skillRoot 'SKILL.md'
  Write-Text $skillPath "---`nname: native-fixture`ndescription: Synthetic native regression.`n---`nBody.`n"
  $lines = [Collections.Generic.List[string]]::new()
  $lines.Add((Json (Meta 'native-main')))
  $lines.Add((Json (Context 'native-turn')))
  $lines.Add((Json (Event '2026-10-14T15:51:00Z' 'event_msg' @{ type = 'task_started'; turn_id = 'native-turn' })))
  for ($index = 0; $index -lt 96; $index++) {
    $lines.Add((Json (Event '2026-10-14T15:52:00Z' 'response_item' @{ type = 'message'; content = @(@{ type = 'input_text'; text = 'Fake {"type":"token_count","payload":{"type":"session_meta"}} PRIVATE_NATIVE_BODY_SENTINEL' }) })))
  }
  $lines.Add('')
  $lines.Add('{broken-json-with-fake-type-token_count')
  $lines.Add((Json (Record '2026-10-14T15:59:57Z' 'native-response-matched' (Vector 100 10 30) (Vector 100 10 30))))
  $lines.Add((Json (Token '2026-10-14T15:59:58Z' (Vector 0 0) (Vector 0 0))))
  $ordered = [ordered]@{ payload = @{ info = @{ last_token_usage = (Vector 100 10 30); total_token_usage = (Vector 100 10 30) }; type = 'token_count'; turn_id = 'native-turn' }; timestamp = '2026-10-14T15:59:59Z'; type = 'event_msg' }
  $escaped = (Json $ordered).Replace('"payload"', '"pay\u006coad"').Replace('"type"', '"\u0074ype"').Replace('"token_count"', '"toke\u006e_count"')
  $lines.Add($escaped)
  $call = @{ name = 'exec_command'; type = 'function_call'; arguments = (Json @{ cmd = "Get-Content -LiteralPath '$skillPath'"; workdir = $a.source }) }
  $lines.Add((Json (Event '2026-10-14T16:00:01Z' 'response_item' $call)))
  $lines.Add((Json (Event '2026-10-14T16:00:02Z' 'event_msg' @{ type = 'compacted'; window_id = 'native-window' })))
  $lines.Add((Json (Event '2026-10-14T16:00:02.100Z' 'event_msg' @{ type = 'context_compacted'; window_id = 'native-window' })))
  $lines.Add((Json (Event '2026-10-14T16:00:03Z' 'event_msg' @{ type = 'task_complete'; turn_id = 'native-turn'; duration_ms = 1234; time_to_first_token_ms = 125 })))
  $lines.Add((Json (Context 'native-next' 'fixture-native-next' '2026-10-14T16:00:04Z')))
  $lines.Add((Json (Record '2026-10-14T16:00:05Z' 'native-response-orphan' (Vector 40 4 8) (Vector 140 14 38) 'native-next')))
  Write-Lines (Join-Path $a.sessions 'a.jsonl') $lines.ToArray()
  Write-Lines (Join-Path $a.sessions 'g.jsonl') @(
    (Json (Meta 'native-guardian' 'guardian')),
    (Json (Context 'native-turn' 'codex-auto-review')),
    (Json (Token '2026-10-14T16:00:00Z' (Vector 20 2) (Vector 20 2)))
  )
  Pair '01-source-cold' $a -CompareEvents
  Pair '02-source-warm' $a -CompareEvents
  $park = Join-Path $a.root 'u'
  New-Item -ItemType Directory -Path $park -Force | Out-Null
  foreach ($file in @(Get-ChildItem -LiteralPath $a.sessions -File -Filter '*.jsonl')) {
    Move-Item -LiteralPath (Test-PathBound $file.FullName) -Destination (Test-PathBound (Join-Path $park $file.Name))
  }
  Pair '03-source-migrated-to-history' $a

  # Exact a/i ties change adjacency when an unstable sort permutes equal keys.
  # Enough colliding records exercise both engines' actual tie behavior.
  $b = New-Case '2'
  for ($index = 0; $index -lt 40; $index++) {
    $amount = 10 + ($index % 3)
    Write-Lines (Join-Path $b.sessions ($index.ToString('00') + '.jsonl')) @(
      (Json (Meta 'native-tie-thread')),
      (Json (Context 'native-turn' 'fixture-tie')),
      (Json (Token '2026-10-14T16:00:00Z' (Vector $amount 1) (Vector $amount 1)))
    )
  }
  $ids = @('z', 'a', 'Z', 'b', [string][char]0x00c5, ('A' + [char]0x030a), [string][char]0x00df, 'ss', 'I', 'i', [string][char]0x0130, [string][char]0x0131)
  for ($index = 0; $index -lt $ids.Count; $index++) {
    Write-Lines (Join-Path $b.sessions ('u' + $index.ToString('00') + '.jsonl')) @(
      (Json (Meta $ids[$index])),
      (Json (Context 'native-turn' 'fixture-collation')),
      (Json (Token '2026-10-14T16:00:01Z' (Vector (30 + $index) 1) (Vector (30 + $index) 1)))
    )
  }
  Pair '04-ties-and-unicode-default' $b -CompareEvents
  Pair '05-ties-and-unicode-warm' $b -CompareEvents
  Pair '06-turkish-current-culture' $b -Culture 'tr-TR'

  # Legal numeric JSON spellings must keep the host's Decimal/Double conversion
  # and state-string behavior; invalid values must take the source rebuild path.
  $c = New-Case '3'
  Write-Lines (Join-Path $c.sessions 'n.jsonl') @(
    (Json (Meta 'native-numeric')),
    (Json (Context 'native-turn' 'fixture-number-source')),
    (Json (Token '2026-10-14T16:00:00Z' (Vector 10 1 2) (Vector 10 1 2)))
  )
  Pair '07-number-cache-seed' $c -CompareEvents
  $numberEvents = @(
    (Cached-Count 1 '[10,2,1,0,11]' '[100,20,10,0,110]'),
    (Cached-Count 2 '[1.0e1,2.00e0,1.00e0,0e0,11e0]' '[1e2,2e1,1e1,0e0,1.1e2]'),
    (Cached-Count 3 '[10.0,2.0,1.0,0.0,11.0]' '[100.0,20.0,10.0,0.0,110.0]'),
    # Keep fresh within the old PS 5.1 Math.Max(0, ...) binder's Int32 range.
    # The near-safe integer still exercises the JSON number parser and sums.
    (Cached-Count 4 '[9007199254740000,9007199254740000,0,0,9007199254740000]' '[9007199254740000,9007199254740000,0,0,9007199254740000]'),
    '{"s":"native-numeric","a":"2026-10-14T16:00:05.0000000+00:00","i":5,"k":"task_complete","mo":"fixture-number","ef":"high","sc":"task","turn":"native-turn","du":0.00000000000000000000000000001,"ft":1.0e-1,"hf":true,"er":false}',
    '{"s":"native-numeric","a":"2026-10-14T16:00:06.0000000+00:00","i":6,"k":"compacted","mo":"fixture-number","ef":"high","sc":"task","w":"unicode-\u00e9-\ud83d\ude80","l":{"unused":1.0},"t":[1e0,2]}',
    '{"s":"native-numeric","a":"2026-10-14T16:00:07.0000000+00:00","i":7,"k":"compacted","mo":"fixture-number","ef":"high","sc":"task","w":9223372036854775808}',
    '{"s":"native-numeric","a":"2026-10-14T16:00:07.0000000+00:00","i":8,"k":"context_compacted","mo":"fixture-number","ef":"high","sc":"task","w":"9223372036854775808"}'
  )
  Patch-Cache $c $numberEvents
  Pair '08-legal-cache-numbers' $c -CompareEvents
  Pair '09-legal-cache-numbers-warm' $c -CompareEvents
  $badVariants = @(
    @{ name = '10-string-number-rebuild'; last = '["10",2,1,0,11]'; model = '"fixture-number"' },
    @{ name = '11-boolean-number-rebuild'; last = '[true,2,1,0,11]'; model = '"fixture-number"' },
    @{ name = '12-over-safe-integer-rebuild'; last = '[9007199254740992,0,0,0,9007199254740992]'; model = '"fixture-number"' },
    @{ name = '13-microsoft-date-conversion'; last = '[10,2,1,0,11]'; model = '"\/Date(0)\/"' },
    @{ name = '14-iso-date-conversion'; last = '[10,2,1,0,11]'; model = '"2026-10-15T00:00:00Z"' }
  )
  foreach ($variant in $badVariants) {
    Patch-Cache $c @((Cached-Count 1 $variant.last '[100,20,10,0,110]' $variant.model))
    Pair $variant.name $c -CompareEvents
  }
  $parkedNumber = Join-Path $c.root 'u'
  Move-Item -LiteralPath (Test-PathBound (Join-Path $c.sessions 'n.jsonl')) -Destination (Test-PathBound $parkedNumber)
  Pair '15-number-history-after-migration' $c

  # The old T helper converts single-element type arrays to strings. A probe
  # that only recognizes JSON string tokens must retain these uncertain lines.
  $d = New-Case '4'
  $arrayMeta = Meta 'native-array-type'
  $arrayMeta.type = @('session_meta')
  $arrayContext = Context 'native-array-turn' 'fixture-array-type'
  $arrayContext.type = @('turn_context')
  $arrayStart = Event '2026-10-14T15:59:50Z' 'event_msg' @{ type = @('task_started'); turn_id = 'native-array-turn' }
  $arrayRecord = Record '2026-10-14T15:59:58Z' 'native-array-response' (Vector 10 1 2) (Vector 10 1 2) 'native-array-turn'
  $arrayRecord.type = @('token_usage_record')
  $arrayCount = Token '2026-10-14T15:59:59Z' (Vector 10 1 2) (Vector 10 1 2) 'native-array-turn'
  $arrayCount.payload.type = @('token_count')
  $arrayRootCount = Token '2026-10-14T16:00:01Z' (Vector 20 2 4) (Vector 30 3 6) 'native-array-turn'
  $arrayRootCount.type = @('event_msg')
  $arrayComplete = Event '2026-10-14T16:00:02Z' 'event_msg' @{ type = @('task_complete'); turn_id = 'native-array-turn'; duration_ms = 2000; time_to_first_token_ms = 250 }
  Write-Lines (Join-Path $d.sessions 'a.jsonl') @(
    (Json $arrayMeta), (Json $arrayContext), (Json $arrayStart),
    (Json $arrayRecord), (Json $arrayCount), (Json $arrayRootCount), (Json $arrayComplete)
  )
  Pair '16-array-type-conservatively-retained' $d -CompareEvents
  foreach ($output in @($d.baseline, $d.candidate)) {
    $arrayData = Read-Json (Join-Path $output 'codex-usage-dashboard-data.json')
    Check 'single-element type arrays produce observed consumption' ($arrayData.usage | Measure-Object -Property total -Sum).Sum 33
    Check 'single-element type arrays preserve the task lifecycle' @($arrayData.tasks).Count 1
    Check 'single-element type arrays preserve response matching' $arrayData.refresh.supplementalTokenRequests 0
  }
  Check 'baseline remains fixed at completion' (Get-FileHash -LiteralPath $baselinePath -Algorithm SHA256).Hash $baselineHash
  Check 'candidate remains fixed at completion' (Get-FileHash -LiteralPath $generatorPath -Algorithm SHA256).Hash $generatorHash
} catch { $failure = $_ }

$result = [ordered]@{ passed = ($null -eq $failure); assertions = $checks; scenarios = $scenarios.Count; engine = $PSVersionTable.PSVersion.ToString(); baselineSha256 = $baselineHash; generatorSha256 = $generatorHash; runRoot = $runRoot; cases = @($scenarios) }
if ($failure) { $result.failure = [string]$failure }
Write-Text (Join-Path $runRoot 'result.json') (Json $result)
$result | ConvertTo-Json -Depth 6 -Compress
if ($failure) { throw $failure }
