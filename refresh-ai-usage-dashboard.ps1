# Local-only dashboard generator. Reads Codex JSONL but never writes to it.
[CmdletBinding()]
param(
  [string]$SourceRoot,
  [string]$OutputRoot,
  [string]$MutexName='Local\CodexUsageDashboardRefresh',
  [switch]$RecoverHistoricalCaches,
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string]$AsOfDate
)
$ErrorActionPreference='Stop'
if(-not $OutputRoot){$OutputRoot=$PSScriptRoot}
if(-not (Test-Path -LiteralPath $OutputRoot)){New-Item -ItemType Directory -Path $OutputRoot -Force|Out-Null}
$out=Join-Path $OutputRoot 'codex-usage-dashboard.html'
$dataOut=Join-Path $OutputRoot 'codex-usage-dashboard-data.json'
$cacheDir=Join-Path $OutputRoot '.codex-usage-dashboard-cache'
$manifestPath=Join-Path $cacheDir 'manifest.json'
$cacheVersion=7
$tz=[TimeSpan]::FromHours(8)
$m=New-Object Threading.Mutex($false,$MutexName)
try {$mutexAcquired=$m.WaitOne(300000)}
catch [Threading.AbandonedMutexException] {$mutexAcquired=$true}
if(-not $mutexAcquired){$m.Dispose();exit 23}

try {
  $generationTimer=[Diagnostics.Stopwatch]::StartNew()
  $phaseTimes=[ordered]@{};$phaseClock=@{ms=0}
  function MarkPhase([string]$name){
    $now=$generationTimer.ElapsedMilliseconds
    $phaseTimes[$name]=$now-$phaseClock.ms;$phaseClock.ms=$now
  }
  # Keep the same strict event contract while avoiding a PowerShell interpreter
  # loop for every field of every retained event. No source JSONL is changed.
  if(-not ('AiUsageEventOpsV1' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Text;

public static class AiUsageEventOpsV1 {
    private static readonly HashSet<string> Kinds = new HashSet<string>(
        new[] { "token_count", "token_usage_record", "thread_settings_applied", "task_started", "task_complete", "compacted", "context_compacted", "skill_read" }, StringComparer.InvariantCultureIgnoreCase);
    private static readonly HashSet<string> Sources = new HashSet<string>(
        new[] { "personal", "workspace", "system", "plugin", "unknown" }, StringComparer.InvariantCultureIgnoreCase);
    private static readonly string[] Fields = { "mo", "ef", "sc", "turn", "r", "l", "t", "du", "ft", "hf", "er", "w", "skill", "source" };
    private static object Value(PSObject item, string name) {
        PSPropertyInfo property = item.Properties[name];
        return property == null ? null : property.Value;
    }
    private static bool Is(object value, string text) {
        return value is string && String.Equals((string)value, text, StringComparison.InvariantCultureIgnoreCase);
    }
    private static bool Text(object value) { return value is string && !String.IsNullOrWhiteSpace((string)value); }
    private static void Fail(string reason) { throw new InvalidOperationException(reason); }
    private static double Number(object value, bool integer, bool bounded) {
        if (value == null || value is bool || value is string) Fail("Invalid stored numeric value");
        double number = LanguagePrimitives.ConvertTo<double>(value);
        if (Double.IsNaN(number) || Double.IsInfinity(number) || number < 0 ||
            (bounded && number > 9007199254740991d) || (integer && Math.Floor(number) != number)) Fail("Invalid stored numeric value");
        return number;
    }
    private static double[] Vector(object value) {
        IEnumerable sequence = value as IEnumerable;
        if (sequence == null || value is string || value is IDictionary) { Fail("Invalid stored usage vector"); }
        List<double> numbers = new List<double>(5);
        foreach (object number in sequence) numbers.Add(Number(number, true, true));
        if (numbers.Count != 5) Fail("Invalid stored usage vector");
        return numbers.ToArray();
    }
    private static DateTimeOffset Timestamp(object value) {
        if (value is DateTimeOffset) return (DateTimeOffset)value;
        if (value is DateTime) return new DateTimeOffset((DateTime)value);
        return DateTimeOffset.Parse(LanguagePrimitives.ConvertTo<string>(value), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
    }
    public static List<PSObject> Validate(object[] events) {
        List<PSObject> result = new List<PSObject>(events.Length);
        foreach (object raw in events) {
            if (raw == null) Fail("Invalid stored event");
            PSObject item = PSObject.AsPSObject(raw);
            object kind = Value(item, "k"), session = Value(item, "s"), at = Value(item, "a");
            if (!Text(session) || !(kind is string) || !Kinds.Contains((string)kind) || at == null ||
                String.IsNullOrEmpty(LanguagePrimitives.ConvertTo<string>(at))) Fail("Invalid stored event");
            string timestamp = Timestamp(at).ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);
            if (Number(Value(item, "i"), true, true) < 1) Fail("Invalid stored event order");
            object turn = Value(item, "turn");
            if (item.Properties["turn"] != null && !Text(turn)) Fail("Invalid stored turn");
            if (Is(kind, "skill_read")) {
                object source = Value(item, "source");
                if (!Text(turn) || !Text(Value(item, "skill")) || !(source is string) || !Sources.Contains((string)source)) Fail("Invalid stored skill event");
            } else if (!Text(Value(item, "mo")) || !Text(Value(item, "ef")) ||
                       !(Is(Value(item, "sc"), "task") || Is(Value(item, "sc"), "auto_review"))) Fail("Invalid stored attribution");
            if (Is(kind, "token_count") || Is(kind, "token_usage_record")) {
                bool response = Is(kind, "token_usage_record");
                foreach (string name in new[] { "l", "t" }) {
                    double[] vector = Vector(Value(item, name));
                    // Legacy cumulative token_count vectors are state markers.
                    if ((response || name == "l") && (vector[1] > vector[0] || vector[3] > vector[2])) Fail("Invalid stored usage composition");
                    if (response && vector[4] != vector[0] + vector[2]) Fail("Invalid stored response usage");
                }
                if (response) {
                    string identity = LanguagePrimitives.ConvertTo<string>(Value(item, "r"));
                    if (identity == null || !System.Text.RegularExpressions.Regex.IsMatch(identity, "^[a-f0-9]{64}$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) Fail("Invalid stored response identity");
                }
            }
            if ((Is(kind, "task_started") || Is(kind, "task_complete")) && !Text(turn)) Fail("Invalid stored turn identity");
            if (Is(kind, "task_complete")) {
                foreach (string name in new[] { "du", "ft" }) {
                    object duration = Value(item, name);
                    if (duration != null) Number(duration, false, false);
                }
                if (!(Value(item, "hf") is bool) || !(Value(item, "er") is bool)) Fail("Invalid stored turn status");
            }
            PSObject projected = new PSObject();
            projected.Properties.Add(new PSNoteProperty("s", session));
            projected.Properties.Add(new PSNoteProperty("a", timestamp));
            projected.Properties.Add(new PSNoteProperty("i", Value(item, "i")));
            projected.Properties.Add(new PSNoteProperty("k", kind));
            foreach (string name in Fields) {
                PSPropertyInfo property = item.Properties[name];
                if (property != null) projected.Properties.Add(new PSNoteProperty(name, property.Value));
            }
            result.Add(projected);
        }
        return result;
    }
    public static string StringIdentity(object[] fields) {
        // The common token/Skill fields contain only strings and null. Encode
        // them without delimiter collisions; uncommon typed values use JSON.
        StringBuilder key = new StringBuilder("S");
        foreach (object value in fields) {
            if (value == null) { key.Append('N'); continue; }
            string text = value as string;
            if (text == null) return null;
            key.Append('S').Append(text.Length).Append(':').Append(text);
        }
        return key.ToString();
    }
    private static string VectorText(object value, string separator, int count) {
        // PowerShell @($value) treats a scalar string/dictionary/object as one
        // item. Non-token events may carry these unused legacy l/t fields.
        if (value == null) return "";
        IEnumerable sequence = value as IEnumerable;
        if (sequence == null || value is string || value is IDictionary || value is PSObject)
            return LanguagePrimitives.ConvertTo<string>(value);
        StringBuilder text = new StringBuilder();
        int index = 0;
        foreach (object number in sequence) {
            if (index == count) break;
            if (index++ > 0) text.Append(separator);
            text.Append(LanguagePrimitives.ConvertTo<string>(number));
        }
        return text.ToString();
    }
    private static long Consumption(PSObject item) {
        IList vector = (IList)Value(item, "l");
        return LanguagePrimitives.ConvertTo<long>(vector[0]) + LanguagePrimitives.ConvertTo<long>(vector[2]);
    }
    public static void AddSource(object[] events, bool historical, HashSet<string> identities,
                                 List<object> all, Hashtable matched, ScriptBlock jsonFallback) {
        Dictionary<string, PSObject> pending = new Dictionary<string, PSObject>(StringComparer.OrdinalIgnoreCase);
        foreach (object raw in events) {
            PSObject item = PSObject.AsPSObject(raw);
            string session = (string)Value(item, "s");
            object kind = Value(item, "k");
            if (Is(kind, "token_usage_record")) pending[session] = item;
            else if (Is(kind, "task_started") || Is(kind, "task_complete")) pending.Remove(session);
            else if (Is(kind, "token_count")) {
                bool proven = false;
                if (Consumption(item) > 0) {
                    PSObject candidate;
                    if (pending.TryGetValue(session, out candidate) &&
                        String.Equals(LanguagePrimitives.ConvertTo<string>(Value(candidate, "turn")), LanguagePrimitives.ConvertTo<string>(Value(item, "turn")), StringComparison.InvariantCultureIgnoreCase) &&
                        VectorText(Value(candidate, "l"), "|", 4) == VectorText(Value(item, "l"), "|", 4)) {
                        proven = true;
                        matched[LanguagePrimitives.ConvertTo<string>(Value(candidate, "r"))] = true;
                    }
                    pending.Remove(session);
                }
                PSPropertyInfo property = item.Properties["provenResponse"];
                if (property == null) item.Properties.Add(new PSNoteProperty("provenResponse", proven));
                else property.Value = proven;
            }
            object last = Value(item, "l"), cumulative = Value(item, "t");
            object[] fields = { session, Value(item, "a"), kind, Value(item, "mo"), Value(item, "ef"), Value(item, "sc"), Value(item, "turn"), Value(item, "r"),
                last == null ? "" : VectorText(last, ",", Int32.MaxValue), cumulative == null ? "" : VectorText(cumulative, ",", Int32.MaxValue),
                Value(item, "du"), Value(item, "ft"), Value(item, "hf"), Value(item, "er"), Value(item, "w"), Value(item, "skill"), Value(item, "source") };
            string identity = StringIdentity(fields);
            if (identity == null) identity = LanguagePrimitives.ConvertTo<string>(jsonFallback.InvokeReturnAsIs(new object[] { fields }));
            bool first = identities.Add(identity);
            if (!historical || first) all.Add(item);
        }
    }
    public static int ReleaseCoveredRecords(List<object> events, Hashtable matched) {
        // Every covered record was already skipped by aggregation. Retain one
        // per thread so even a covered-only group keeps its old session alias.
        HashSet<string> retainedThreads = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return events.RemoveAll(delegate(object raw) {
            PSObject item = PSObject.AsPSObject(raw);
            if (!Is(Value(item, "k"), "token_usage_record") ||
                !matched.ContainsKey(LanguagePrimitives.ConvertTo<string>(Value(item, "r")))) return false;
            return !retainedThreads.Add(LanguagePrimitives.ConvertTo<string>(Value(item, "s")));
        });
    }
}
'@
  }
  function T($o,$n){
    if($null -eq $o){return $null}
    $p=$o.PSObject.Properties[$n]
    if($null -eq $p -or $null -eq $p.Value){return $null}
    [string]$p.Value
  }
  function N($o,$n){$x=T $o $n;try{[int64]$x}catch{0}}
  function ParseTimestamp($value){
    # ConvertFrom-Json returns DateTime on newer PowerShell and a string on 5.1.
    # Never stringify a DateTime through the generic field helper: that loses Z.
    if($value -is [DateTimeOffset]){return $value}
    if($value -is [DateTime]){return [DateTimeOffset]::new($value)}
    [DateTimeOffset]::Parse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  }
  function Seconds($o,$name){
    $property=$o.PSObject.Properties[$name]
    if($null -eq $property -or $null -eq $property.Value){return $null}
    if($property.Value -is [bool] -or $property.Value -is [string]){return $null}
    try {
      $value=[double]$property.Value
      if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0){return $null}
      return $value/1000
    } catch {return $null}
  }
  function UsageVector($value){
    if($null -eq $value){return $null}
    $values=@()
    foreach($name in 'input_tokens','cached_input_tokens','output_tokens','reasoning_output_tokens'){
      $property=$value.PSObject.Properties[$name]
      if($null -eq $property){if($name -in 'input_tokens','output_tokens'){return $null};$values+=0;continue}
      $number=$property.Value
      if($null -eq $number -or $number -is [bool] -or $number -is [string]){return $null}
      try {$numeric=[double]$number}catch{return $null}
      if([double]::IsNaN($numeric) -or [double]::IsInfinity($numeric) -or $numeric -lt 0 -or $numeric -gt 9007199254740991 -or [Math]::Floor($numeric) -ne $numeric){return $null}
      $values+=[int64]$number
    }
    if($values[1] -gt $values[0] -or $values[3] -gt $values[2]){return $null}
    return ,@($values[0],$values[1],$values[2],$values[3],($values[0]+$values[2]))
  }
  function UsageState($event){
    # Ignore reported totals: input/output are the consumption basis.
    [string]$event.s+'|'+(@($event.l)[0..3]-join '|')+'|'+(@($event.t)[0..3]-join '|')
  }
  function DiskPath([string]$path){
    # Windows PowerShell 5.1's .NET APIs otherwise fail on nested history paths.
    if([IO.Path]::DirectorySeparatorChar -eq '\' -and -not $path.StartsWith('\\?\')){
      $full=[IO.Path]::GetFullPath($path)
      if($full.Length -lt 240){return $full}
      if($full.StartsWith('\\')){return '\\?\UNC\'+$full.Substring(2)}
      return '\\?\'+$full
    }
    return $path
  }
  function WriteAtomicText([string]$path,[string]$content){
    $path=DiskPath $path
    $temporary=$path+'.tmp'
    [IO.File]::WriteAllText($temporary,$content,[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($path)){[IO.File]::Replace($temporary,$path,[System.Management.Automation.Language.NullString]::Value)}
    else{[IO.File]::Move($temporary,$path)}
  }
  function Day($d){$d.ToOffset($tz).ToString('yyyy-MM-dd')}
  function PathKey($path){
    $sha=[Security.Cryptography.SHA256]::Create()
    try {([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path))).Replace('-','')).ToLowerInvariant()}
    finally {$sha.Dispose()}
  }
  function EventSignature($file){
    $info=Get-Item -LiteralPath $file.FullName
    '{0}|{1}' -f $info.Length,$info.LastWriteTimeUtc.Ticks
  }
  # Skill reads are a conservative proxy. Never execute logged shell/JavaScript.
  function ExcludeSkillSession($p){
    if((T $p parent_thread_id) -or (T $p agent_role) -match 'guardian|subagent'){return $true}
    $agentPath=T $p agent_path
    if($agentPath -and $agentPath.TrimEnd('/') -notin '/root','root'){return $true}
    foreach($field in 'source','thread_source'){
      $value=$p.PSObject.Properties[$field]
      if($value -and $value.Value){
        if($value.Value -is [string]){if($value.Value -match 'guardian|subagent'){return $true}}
        elseif($value.Value.PSObject.Properties['subagent'] -or $value.Value.PSObject.Properties['guardian']){return $true}
      }
    }
    return $false
  }
  function AutoReviewSession($p){
    if((T $p thread_source) -match 'guardian|auto_review' -or (T $p agent_role) -match 'guardian|auto_review'){return $true}
    foreach($field in 'source','thread_source'){
      $value=$p.PSObject.Properties[$field]
      if($value -and $value.Value){
        if($value.Value -is [string]){if($value.Value -match 'guardian|auto_review'){return $true}}
        elseif((T $value.Value.subagent other) -eq 'guardian' -or $value.Value.PSObject.Properties['guardian']){return $true}
      }
    }
    return $false
  }
  function LiteralValue($node){
    if($node -is [System.Management.Automation.Language.StringConstantExpressionAst]){return [string]$node.Value}
    if($node -is [System.Management.Automation.Language.ConstantExpressionAst] -and $null -ne $node.Value){return [string]$node.Value}
    if($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $node.NestedExpressions.Count -eq 0){return [string]$node.Value}
    if($node -is [System.Management.Automation.Language.ArrayLiteralAst]){foreach($item in $node.Elements){LiteralValue $item}}
  }
  function NormalizeSkillPath([string]$path,[string]$cwd){
    $path=$path.Replace('\','/')
    if($path.StartsWith('~/')){$path=$skillHomeParent+'/'+$path.Substring(2)}
    elseif($path -notmatch '^(?:[a-zA-Z]:/|/)'){
      if(-not $cwd){return $path}
      $path=$cwd.Replace('\','/').TrimEnd('/')+'/'+$path
    }
    $segments=[Collections.Generic.List[string]]::new()
    foreach($part in ($path -split '/')){
      if($part -eq '.' -or $part -eq ''){continue}
      if($part -eq '..'){if($segments.Count -gt 0){$segments.RemoveAt($segments.Count-1)};continue}
      $segments.Add($part)
    }
    ($segments -join '/').ToLowerInvariant()
  }
  function SkillIdentity([string]$path,[string]$cwd){
    if($path -notmatch '(?i)(?:^|[/\\])SKILL\.md$'){return}
    $normalized=NormalizeSkillPath $path $cwd
    $source='unknown';$name=$null
    $safe='[a-z0-9][a-z0-9._-]{0,99}'
    if($normalized -match ('(?:^|/)skills/(?:\.system/)?(?<skill>'+ $safe +')/skill\.md$')){
      $name=$Matches.skill
      if($normalized -match ('(?:^|/)plugins/(?:cache/)?[^/]+/(?<plugin>'+ $safe +')/[^/]+/skills/')){
        $source='plugin';$name=$Matches.plugin+':'+$name
      }elseif($normalized -match '(?:^|/)skills/\.system/'){$source='system'}
      elseif($normalized.StartsWith($skillHomeKey+'/skills/') -or $normalized.StartsWith($skillHomeParentKey+'/.codex/skills/') -or $normalized.StartsWith($skillHomeParentKey+'/.agents/skills/') -or $normalized -match '^(?:[a-z]:/users/[^/]+|users/[^/]+|home/[^/]+|root)/(?:\.codex|\.agents)/skills/'){$source='personal'}
      elseif($normalized -match '(?:^|/)(?:\.codex/|\.agents/)?skills/'){$source='workspace'}
    }
    # Unknown layouts get an opaque label, never a parent folder/user name.
    if(-not $name){$name='unknown-'+(PathKey $normalized).Substring(0,12)}
    [pscustomobject]@{skill=$name;source=$source}
  }
  function ShellSkillReads([string]$command,[string]$cwd){
    if(-not $command -or $command -notmatch '(?i)SKILL\.md'){return}
    $parseTokens=$null;$parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($command,[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors.Count -gt 0){return}
    if($ast.FindAll({param($n) $n.GetType().Name -in 'ReturnStatementAst','ExitStatementAst','ThrowStatementAst','BreakStatementAst','ContinueStatementAst'},$true).Count){return}
    foreach($node in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.CommandAst]},$true)){
      $name=$node.GetCommandName()
      if($name -notin 'Get-Content','gc','cat','type','head','tail','more','bat','sed','Select-String','sls','rg'){continue}
      $safeContext=$true;$ancestor=$node.Parent
      while($ancestor){
        if($ancestor -is [System.Management.Automation.Language.IfStatementAst] -or
           $ancestor -is [System.Management.Automation.Language.LoopStatementAst] -or
           $ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
           $ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
           $ancestor.GetType().Name -in 'PipelineChainAst','SwitchStatementAst','TrapStatementAst','TryStatementAst','BinaryExpressionAst','TernaryExpressionAst'){$safeContext=$false;break}
        $ancestor=$ancestor.Parent
      }
      if(-not $safeContext){continue}
      $readArgs=[Collections.Generic.List[string]]::new()
      foreach($element in @($node.CommandElements|Select-Object -Skip 1)){
        if($element -is [System.Management.Automation.Language.CommandParameterAst]){
          $readArgs.Add('-'+$element.ParameterName)
          foreach($value in @(LiteralValue $element.Argument)){if($value){$readArgs.Add($value)}}
        }else{foreach($value in @(LiteralValue $element)){if($value){$readArgs.Add($value)}}}
      }
      if(@($readArgs|Where-Object {$_ -match '^(?:--help|--version|-h|-V|-\?)$'}).Count){continue}
      if($name -in 'rg','Select-String','sls'){
        # Listing/file-selection modes do not establish a description read.
        if(@($readArgs|Where-Object {$_ -match '^--?(?:files(?:-with-matches|-without-match)?|list|quiet|count(?:-matches)?|type-list|glob|iglob)(?:=|$)' -or $_ -cmatch '^-[^-]*[lLqcg][^-]*$'}).Count){continue}
      }
      if($name -eq 'sed' -and (-not (@($readArgs|Where-Object {$_ -eq '-n' -or $_ -eq '--quiet'}).Count) -or @($readArgs|Where-Object {$_ -match '^-i|^--in-place'}).Count)){continue}
      # Option values (a regex, encoding, etc.) are not file operands.
      $skipValue=$false;$pathValue=$false;$hasPattern=$false;$literalPaths=[Collections.Generic.List[string]]::new()
      $search=$name -in 'rg','Select-String','sls','sed'
      for($ai=0;$ai -lt $readArgs.Count;$ai++){
        $arg=$readArgs[$ai]
        if($skipValue){$skipValue=$false;continue}
        if($pathValue){$literalPaths.Add($arg);$pathValue=$false;continue}
        if($arg -in '-Path','-LiteralPath'){$pathValue=$true;continue}
        if($search -and $arg -in '-Pattern','-e','-f','--regexp','--file','--expression'){$hasPattern=$true;$skipValue=$true;continue}
        if($search -and $arg -match '^--(?:regexp|file|expression)=|^-[ef].+'){$hasPattern=$true;continue}
        if($arg -match '^-(?:Encoding|Delimiter|Include|Exclude|Filter|ReadCount|TotalCount|Head|Tail|First|Last|Context|OutVariable|ErrorVariable|WarningVariable)$' -or
           ($name -in 'head','tail' -and $arg -in '-n','-c','--lines','--bytes') -or
           ($name -eq 'rg' -and $arg -cin '-m','-A','-B','-C','--max-count','--after-context','--before-context','--context','--max-columns','--max-filesize','--threads','--sort','--sortr','--encoding','--color')){$skipValue=$true;continue}
        if($arg.StartsWith('-')){continue}
        if($search -and -not $hasPattern){$hasPattern=$true;continue}
        $literalPaths.Add($arg)
      }
      foreach($path in $literalPaths){SkillIdentity $path $cwd}
    }
  }
  function DecodeJsString([string]$token){
    if($token.Length -lt 2){return $null}
    if($token[0] -eq [char]96 -and $token.Contains('${')){return $null}
    $body=$token.Substring(1,$token.Length-2)
    # Only literal JavaScript escapes; interpolation and evaluation are forbidden.
    [regex]::Replace($body,'\\(?:u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|\r?\n|.)',{
      param($m)
      $v=$m.Value.Substring(1)
      switch -CaseSensitive ($v){
        'n'{return "`n"};'r'{return "`r"};'t'{return "`t"};'b'{return "`b"};'f'{return "`f"};'v'{return [string][char]11};'0'{return [string][char]0}
        default{if($v -match '^u[0-9a-fA-F]{4}$|^x[0-9a-fA-F]{2}$'){return [string][char][Convert]::ToInt32($v.Substring(1),16)};if($v -match '^\r?\n$'){return ''};return $v}
      }
    })
  }
  function WrappedCommands([string]$code,[string]$cwd){
    if(-not $code -or $code -notmatch '(?i)SKILL\.md'){return}
    # Tokenize strings/comments before recognizing calls so quoted code is inert.
    $pattern='(?s)//[^\r\n]*|/\*.*?\*/|/(?:\\.|[^/\\\r\n\[]|\[(?:\\.|[^\]\\])*\])+/[dgimsuvy]*|"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])*''|`(?:\\.|[^`\\])*`|[a-zA-Z_$][\w$]*|=>|&&|\|\||[^\s]'
    $tokens=@([regex]::Matches($code,$pattern)|Where-Object {$_.Value -notmatch '^//|^/\*'}|ForEach-Object {$_.Value})
    $depth=0;$unsafeStatement=$false
    for($j=0;$j -lt $tokens.Count;$j++){
      $token=$tokens[$j]
      if($depth -eq 0 -and ($token -in 'return','throw' -or ($token -eq 'exit' -and $j+1 -lt $tokens.Count -and $tokens[$j+1] -eq '('))){break}
      if($depth -eq 0 -and $token -eq ';'){$unsafeStatement=$false}
      if($depth -eq 0 -and $token -in 'if','for','while','switch','function','=>','&&','||','?','throw'){$unsafeStatement=$true}
      if($token -eq '{'){$depth++;continue}
      if($token -eq '}'){$depth--;if($depth -lt 0){$depth=0};continue}
      if($depth -ne 0 -or $unsafeStatement -or $j+4 -ge $tokens.Count){continue}
      if($token -ne 'tools' -or $tokens[$j+1] -ne '.' -or $tokens[$j+2] -notin 'exec_command','shell_command','shell' -or $tokens[$j+3] -ne '(' -or $tokens[$j+4] -ne '{'){continue}
      $objDepth=1;$literalCommand=$null;$literalWorkdir=$cwd;$validObject=$true;$seenKeys=@{}
      for($n=$j+5;$n -lt $tokens.Count;$n++){
        if($tokens[$n] -eq '{'){$objDepth++}
        if($tokens[$n] -eq '}'){$objDepth--;if($objDepth -eq 0){break}}
        if($objDepth -ne 1 -or $n+3 -ge $tokens.Count){continue}
        if($tokens[$n] -eq '.' -and $tokens[$n+1] -eq '.' -and $tokens[$n+2] -eq '.'){$validObject=$false}
        $key=$tokens[$n];if($key -match '^["'']'){$key=DecodeJsString $key}
        if($key -notin 'cmd','command','workdir','cwd' -or $tokens[$n-1] -notin '{',','){continue}
        if($seenKeys.ContainsKey($key)){$validObject=$false};$seenKeys[$key]=$true
        if($tokens[$n+1] -ne ':' -or $tokens[$n+2] -notmatch '^["''`]' -or $tokens[$n+3] -notin ',', '}'){$validObject=$false;continue}
        $value=DecodeJsString $tokens[$n+2]
        if($key -in 'cmd','command'){$literalCommand=$value}else{$literalWorkdir=$value}
      }
      if($literalCommand -and $validObject){[pscustomobject]@{command=$literalCommand;cwd=$literalWorkdir}}
      $j=$n
    }
  }
  function ToolSkillReads($p,[string]$cwd){
    $name=T $p name
    if($name -in 'exec','functions.exec'){
      $code=T $p input;if(-not $code){$code=T $p arguments}
      foreach($wrapped in @(WrappedCommands $code $cwd)){ShellSkillReads $wrapped.command $wrapped.cwd}
      return
    }
    if($name -notin 'exec_command','functions.exec_command','shell_command','functions.shell_command','shell','functions.shell'){return}
    $raw=$p.arguments;if($null -eq $raw){$raw=$p.input}
    $callArgs=$null
    try {if($raw -is [string]){$callArgs=$raw|ConvertFrom-Json -ErrorAction Stop}else{$callArgs=$raw}}catch{return}
    if(-not $callArgs){return}
    $workdir=T $callArgs workdir;if(-not $workdir){$workdir=T $callArgs cwd};if(-not $workdir){$workdir=$cwd}
    $command=$callArgs.cmd;if($null -eq $command){$command=$callArgs.command}
    if($command -is [string]){ShellSkillReads $command $workdir}
    elseif($command -is [array] -and $command.Count -ge 3){
      # shell argv: a literal script supplied with -c/-Command (never join argv).
      for($ci=1;$ci -lt $command.Count-1;$ci++){
        if($command[$ci] -in '-c','-lc','-Command','-command'){ShellSkillReads ([string]$command[$ci+1]) $workdir;break}
      }
    }
  }
  function ReadEvents($file){
    $events=[Collections.Generic.List[object]]::new()
    $reader=$null;$sid=$null;$lineNo=0;$turn=$null;$cwd=$null;$fileExcludeSkills=$false;$pendingUsage=$null
    $mo='unknown';$ef='unknown';$fileScope='task'
    try {
      $reader=[IO.StreamReader]::new([IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite))
      while(($line=$reader.ReadLine()) -ne $null){
        $lineNo++
        try {$x=$line|ConvertFrom-Json -EA Stop}catch{continue}
        $p=$x.payload;$kind=T $p type;if(!$kind){$kind=T $x type}
        if($kind -eq 'session_meta'){
          # id is the actual thread; session_id can name its parent task.
          $sid=T $p id;if(!$sid){$sid=T $p session_id};$turn=$null;$cwd=T $p cwd;$pendingUsage=$null
          if(AutoReviewSession $p){$fileScope='auto_review'}
          if(ExcludeSkillSession $p){$fileExcludeSkills=$true};continue
        }
        if((T $x type) -eq 'turn_context'){
          $turn=T $p turn_id;if(T $p cwd){$cwd=T $p cwd}
          if(T $p model){$mo=T $p model}
          $effort=T $p effort;if(!$effort){$effort=T $p reasoning_effort};if($effort){$ef=$effort}
          continue
        }
        if($kind -eq 'thread_settings_applied'){
          $settings=$p.thread_settings
          if(T $settings model){$mo=T $settings model}
          $effort=T $settings reasoning_effort;if(!$effort){$effort=T $settings effort};if($effort){$ef=$effort}
        }
        if($kind -eq 'task_started'){$turn=T $p turn_id}
        if((T $x type) -eq 'response_item' -and $kind -in 'custom_tool_call','function_call'){
          $callTurn=T $p turn_id;if(-not $callTurn){$callTurn=$turn}
          $session=$sid;if(-not $session){$session=T $p session_id}
          if(-not $fileExcludeSkills -and $session -and $callTurn){
            try {$at=ParseTimestamp $x.timestamp}catch{continue}
            foreach($skill in @(ToolSkillReads $p $cwd)){
              $events.Add([pscustomobject][ordered]@{s=$session;a=$at.ToUniversalTime().ToString('o');i=$lineNo;k='skill_read';turn=$callTurn;skill=$skill.skill;source=$skill.source})
            }
          }
          continue
        }
        if($kind -in 'task_complete','turn_aborted'){$turn=$null}
        if($kind -notin 'token_count','token_usage_record','thread_settings_applied','task_started','task_complete','compacted','context_compacted'){continue}
        $session=$sid;if(!$session){$session=T $p session_id};if(!$session){continue}
        try {$at=ParseTimestamp $x.timestamp}catch{continue}
        # Bind attribution in the source thread before combining any files.
        $scope=if($fileScope -eq 'auto_review' -or $mo -eq 'codex-auto-review'){'auto_review'}else{'task'}
        $e=[ordered]@{s=$session;a=$at.ToUniversalTime().ToString('o');i=$lineNo;k=$kind;mo=$mo;ef=$ef;sc=$scope}
        switch($kind){
          'token_usage_record' {
            $pendingUsage=$null
            $response=T $p response_id;$last=UsageVector $p.usage;$cumulative=UsageVector $p.thread_token_usage
            if($response -and $null -ne $last -and $null -ne $cumulative){
              $recordTurn=T $p turn_id;if(!$recordTurn){$recordTurn=$turn};if($recordTurn){$e.turn=$recordTurn}
              $e.r=PathKey $response;$e.l=$last;$e.t=$cumulative
              $pendingUsage=[pscustomobject]$e;$events.Add($pendingUsage)
            }
          }
          'token_count' {
            $z=$p.info
            if($z -and $z.last_token_usage){
              $tokenTurn=T $p turn_id;if(!$tokenTurn){$tokenTurn=$turn};if($tokenTurn){$e.turn=$tokenTurn}
              $e.l=@((N $z.last_token_usage input_tokens),(N $z.last_token_usage cached_input_tokens),(N $z.last_token_usage output_tokens),(N $z.last_token_usage reasoning_output_tokens),(N $z.last_token_usage total_tokens))
              if($z.total_token_usage){$e.t=@((N $z.total_token_usage input_tokens),(N $z.total_token_usage cached_input_tokens),(N $z.total_token_usage output_tokens),(N $z.total_token_usage reasoning_output_tokens),(N $z.total_token_usage total_tokens))}else{$e.t=@(0,0,0,0,0)}
              if($pendingUsage -and $pendingUsage.s -eq $session -and (@($pendingUsage.l)[0..3]-join '|') -eq (@($e.l)[0..3]-join '|')){$e.r=$pendingUsage.r;$pendingUsage=$null}
              $events.Add([pscustomobject]$e)
            }
          }
          'thread_settings_applied' {$events.Add([pscustomobject]$e)}
          'task_started' {if(T $p turn_id){$e.turn=T $p turn_id;$events.Add([pscustomobject]$e)}}
          'task_complete' {
            if(T $p turn_id){
              $e.turn=T $p turn_id
              $e.du=Seconds $p 'duration_ms'
              $e.ft=Seconds $p 'time_to_first_token_ms'
              $e.hf=($null -ne $e.ft)
              $e.er=($null -ne $p.PSObject.Properties['error'] -and $null -ne $p.error -and $p.error -ne $false)
              $events.Add([pscustomobject]$e)
            }
          }
          default {$e.w=T $p window_id;$events.Add([pscustomobject]$e)}
        }
      }
    } finally {if($reader){$reader.Dispose()}}
    # Enumerate explicitly; Windows PowerShell can serialize an empty List as {}.
    foreach($event in $events){
      if($event.k -ne 'skill_read' -and $fileScope -eq 'auto_review'){$event.sc='auto_review'}
      if($event.k -ne 'skill_read' -or -not $fileExcludeSkills){$event}
    }
  }

  function GetParserFingerprint([string]$SourceText){
    # Presentation and aggregation edits must not invalidate extracted events.
    # Changes outside these functions that affect extraction require a version bump.
    $parseTokens=$null;$parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($SourceText,[ref]$parseTokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Cannot fingerprint an invalid generator'}
    $names=@('T','N','ParseTimestamp','Seconds','UsageVector','PathKey','ExcludeSkillSession','AutoReviewSession','LiteralValue','NormalizeSkillPath','SkillIdentity','ShellSkillReads','DecodeJsString','WrappedCommands','ToolSkillReads','ReadEvents')
    $parts=@(foreach($name in $names){
      $fn=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
      if(-not $fn){throw 'Missing event parser function'}
      $fn.Extent.Text.Replace("`r`n","`n")
    })
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
      $value='event-parser-v1|5|'+($parts -join "`n")
      ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))).Replace('-','')).ToLowerInvariant()
    } finally {$sha.Dispose()}
  }

  # Current Skill descriptions are metadata, never evidence of a Skill read.
  # Only known Skill layouts are visited; session bodies are not searched for paths.
  function SafeSkillMetadataText([string]$value,[int]$limit){
    $value=[regex]::Replace($value,'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]',' ')
    $value=[regex]::Replace($value,'\s+',' ').Trim()
    # Withhold an entire field when it could expose local identity or credentials.
    # This avoids incomplete redaction of quoted paths containing spaces.
    if($value -match '(?i)(?:[a-z]:[\\/]|\\\\|(?:^|[\s"''`(=:])/(?!/)[\w.~-]+(?:/|\b)|file://|~/|%USERPROFILE%|\$(?:HOME|env:USERPROFILE)|sk-[a-z0-9_-]{12,}|bearer\s+[a-z0-9._-]{8,}|(?:api[_-]?key|access[_-]?token|password)\s*[:=])'){return ''}
    foreach($privateName in @($env:USERNAME,(Split-Path -Leaf $skillHomeParent))){
      if($privateName -and $privateName.Length -gt 2 -and $value.IndexOf($privateName,[StringComparison]::OrdinalIgnoreCase) -ge 0){return ''}
    }
    if($value.Length -gt $limit){$value=$value.Substring(0,$limit-1)+'…'}
    return $value
  }
  function ReadSkillFrontmatter([string]$path){
    $result=[ordered]@{name='';description='';bytesRead=0};$reader=$null
    try {
      $reader=[IO.StreamReader]::new($path,[Text.Encoding]::UTF8,$true,1024)
      $lines=[Collections.Generic.List[string]]::new();$line=[Text.StringBuilder]::new();$closed=$false
      # Bound malformed/huge headers. Stop at the frontmatter terminator, never parse body text.
      for($index=0;$index -lt 16384;$index++){
        $next=$reader.Read();if($next -lt 0){break}
        if($next -ne 10){if($next -ne 13){[void]$line.Append([char]$next)};continue}
        $text=$line.ToString();[void]$line.Clear()
        if($lines.Count -eq 0 -and $text -notmatch '^---\s*$'){break}
        if($lines.Count -gt 0 -and $text -match '^---\s*$'){$closed=$true;break}
        $lines.Add($text)
      }
      if(-not $closed -and $lines.Count -gt 0 -and $line.ToString() -match '^---\s*$'){$closed=$true}
      $result.bytesRead=$reader.BaseStream.Position
      if($closed){
        $values=@{};$seen=@{}
        for($i=1;$i -lt $lines.Count;$i++){
          if($lines[$i] -notmatch '^(name|description):\s*(.*)$'){continue}
          $field=$Matches[1];$value=$Matches[2];$parts=[Collections.Generic.List[string]]::new()
          while($i+1 -lt $lines.Count -and ($lines[$i+1] -match '^\s+\S' -or $lines[$i+1].Trim() -eq '')){
            $i++;$parts.Add($lines[$i].Trim())
          }
          if($seen.ContainsKey($field)){$values[$field]='';continue};$seen[$field]=$true
          if($value -match '^(?:[|>][+-]?\s*(?:#.*)?|)$'){$value=$parts -join ' '}
          elseif($parts.Count){$value+=' '+($parts -join ' ')}
          $value=$value.Trim()
          if($value.StartsWith('"')){try{$value=[string](ConvertFrom-Json -InputObject $value)}catch{$value=''}}
          elseif($value.StartsWith("'")){
            if($value.Length -gt 1 -and $value.EndsWith("'")){$value=$value.Substring(1,$value.Length-2).Replace("''","'")}else{$value=''}
          }elseif($value -match '^[\[\]{}&*!]|^-\s|^(?:null|~)$'){$value=''}
          else{$value=[regex]::Replace($value,'\s+#.*$','')}
          $limit=if($field -eq 'name'){160}else{2000}
          $values[$field]=SafeSkillMetadataText $value $limit
        }
        foreach($field in 'name','description'){if($values.ContainsKey($field)){$result[$field]=$values[$field]}}
      }
    }catch{}finally{if($reader){$reader.Dispose()}}
    [pscustomobject]$result
  }
  function LocalMetadataDirectory([string]$path){
    if(-not $path -or $path -match '^(?:\\\\|//)' -or -not [IO.Path]::IsPathRooted($path)){return $false}
    try {
      $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($path));if($drive.DriveType -eq [IO.DriveType]::Network){return $false}
      $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if(-not $item.PSIsContainer){return $false}
      # Do not follow junctions/symlinks out of the declared local metadata roots.
      while($item){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){return $false};$item=$item.Parent}
      return $true
    }catch{return $false}
  }
  function SkillMetadataRoots([string]$homePath){
    $roots=@{};$workspaces=@{}
    foreach($path in @((Join-Path $homePath 'skills'),(Join-Path $homePath 'skills\.system'),(Join-Path (Split-Path -Parent $homePath) '.agents\skills'))){$roots[$path]=$true}
    $pluginCache=Join-Path $homePath 'plugins\cache'
    if(LocalMetadataDirectory $pluginCache){
      foreach($marketplace in @(Get-ChildItem -LiteralPath $pluginCache -Directory -ErrorAction SilentlyContinue)){
        if(-not (LocalMetadataDirectory $marketplace.FullName)){continue}
        foreach($package in @(Get-ChildItem -LiteralPath $marketplace.FullName -Directory -ErrorAction SilentlyContinue)){
          if(-not (LocalMetadataDirectory $package.FullName)){continue}
          foreach($version in @(Get-ChildItem -LiteralPath $package.FullName -Directory -ErrorAction SilentlyContinue)){
            if(LocalMetadataDirectory $version.FullName){$roots[(Join-Path $version.FullName 'skills')]=$true}
          }
        }
      }
    }
    # Only TOML project section keys are used. No configuration is evaluated or exported.
    $config=Join-Path $homePath 'config.toml'
    if(Test-Path -LiteralPath $config -PathType Leaf){
      try {foreach($line in [IO.File]::ReadLines($config)){
        $projectPath=''
        if($line -match '^\s*\[projects\.''([^'']+)''\]\s*(?:#.*)?$'){$projectPath=$Matches[1]}
        elseif($line -match '^\s*\[projects\.("(?:[^"\\]|\\.)+")\]\s*(?:#.*)?$'){
          try{$projectPath=[string](ConvertFrom-Json -InputObject $Matches[1])}catch{}
        }
        if(-not (LocalMetadataDirectory $projectPath)){continue}
        $item=Get-Item -LiteralPath $projectPath
        while($item -and $item.Parent){$workspaces[$item.FullName]=$true;$item=$item.Parent}
      }}catch{}
    }
    foreach($workspace in $workspaces.Keys){
      foreach($relative in '.agents\skills','.codex\skills','skills'){$roots[(Join-Path $workspace $relative)]=$true}
    }
    foreach($path in ($roots.Keys|Sort-Object)){if(LocalMetadataDirectory $path){$path}}
  }
  function GetSkillMetadata($activity,[string]$homePath){
    $observed=@{};foreach($row in $activity){$observed[$row.source+'|'+$row.skill]=$row}
    $path=Join-Path $cacheDir 'skill-metadata.json';$oldEntries=@{};$newEntries=[Collections.Generic.List[object]]::new();$candidates=@{};$visited=@{};$found=@{};$copies=@{}
    # Metadata has its own small cache; metadata changes never invalidate JSONL events.
    if(Test-Path -LiteralPath $path){
      try {
        $stored=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($stored.version -eq 1){foreach($entry in $stored.entries){
          if($entry.key -match '^[a-f0-9]{64}$' -and $entry.name -is [string] -and $entry.description -is [string]){$oldEntries[[string]$entry.key]=$entry}
        }}
      }catch{}
    }
    $cost=[ordered]@{candidates=0;reused=0;reparsed=0;bytesRead=[long]0;cacheBytes=[long]0}
    foreach($root in @(SkillMetadataRoots $homePath)){
      foreach($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)){
        try {
        if(-not (LocalMetadataDirectory $directory.FullName)){continue}
        $filePath=Join-Path $directory.FullName 'SKILL.md'
        if(-not (Test-Path -LiteralPath $filePath -PathType Leaf)){continue}
        $file=Get-Item -LiteralPath $filePath
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
        $identity=SkillIdentity $file.FullName '';if(-not $identity){continue}
        $identityKey=$identity.source+'|'+$identity.skill
        $key=PathKey $file.FullName.ToLowerInvariant();if($visited.ContainsKey($key)){continue};$visited[$key]=$true
        $found[$identityKey]=$identity
        if(-not $copies.ContainsKey($identityKey)){$copies[$identityKey]=0};$copies[$identityKey]++
        $cost.candidates++;$signature=EventSignature $file;$cached=$oldEntries[$key]
        if($cached -and [string]$cached.signature -eq $signature){
          $name=SafeSkillMetadataText ([string]$cached.name) 160;$description=SafeSkillMetadataText ([string]$cached.description) 2000;$cost.reused++
        }else{
          $metadata=ReadSkillFrontmatter $file.FullName;$name=$metadata.name;$description=$metadata.description
          $cost.reparsed++;$cost.bytesRead+=$metadata.bytesRead
        }
        $newEntries.Add([ordered]@{key=$key;signature=$signature;name=$name;description=$description})
        if(-not $candidates.ContainsKey($identityKey)){$candidates[$identityKey]=@{}}
        $variantKey=PathKey ($name+"`0"+$description)
        $candidates[$identityKey][$variantKey]=@{name=$name;description=$description}
        }catch{continue}
      }
    }
    $rows=@(foreach($identityKey in ($observed.Keys|Sort-Object)){
      $item=$observed[$identityKey];$status='missing';$name='';$description=''
      if($candidates.ContainsKey($identityKey)){
        $variants=$candidates[$identityKey]
        if($variants.Count -gt 1){$status='ambiguous'}
        elseif($variants.Count -eq 1){$variant=@($variants.Values)[0];$name=$variant.name;$description=$variant.description;if($name -or $description){$status='available'}}
      }
      [ordered]@{skill=$item.skill;source=$item.source;status=$status;name=$name;description=$description}
    })
    $inventory=@(foreach($identityKey in ($found.Keys|Sort-Object)){
      $item=$found[$identityKey];$status='missing';$name='';$description=''
      if($candidates.ContainsKey($identityKey)){
        $variants=$candidates[$identityKey]
        if($variants.Count -gt 1){$status='ambiguous'}
        elseif($variants.Count -eq 1){$variant=@($variants.Values)[0];$name=$variant.name;$description=$variant.description;if($name -or $description){$status='available'}}
      }
      [ordered]@{skill=$item.skill;source=$item.source;status=$status;name=$name;description=$description;copies=$copies[$identityKey]}
    })
    WriteAtomicText $path ([ordered]@{version=1;entries=@($newEntries)}|ConvertTo-Json -Depth 5 -Compress)
    $cost.cacheBytes=(Get-Item -LiteralPath $path).Length
    [pscustomobject]@{rows=$rows;inventory=$inventory;cost=$cost}
  }

  # Durable structural history is separate from the disposable speed cache.
  # Keep this validation/projection outside the source parser fingerprint: no
  # extraction rule changes, and old source-less events must remain readable.
  function ReadStoredEvents($stored){
    if($stored.version -ne $cacheVersion -or $stored.parser -notin $compatibleParsers -or
      $null -eq $stored.PSObject.Properties['events'] -or $null -eq $stored.events){throw 'Incompatible stored events'}
    [AiUsageEventOpsV1]::Validate([object[]]@($stored.events))
  }
  function HistoryCacheProof([string]$key,[string]$signature,[string]$cacheHash,[string]$historyHash){
    PathKey ($sourceKey+'|'+$parserFingerprint+'|'+$key+'|'+$signature+'|'+$cacheHash+'|'+$historyHash)
  }
  function SaveHistoryEvents([string]$key,[string]$signature,[object[]]$events,[string]$cacheHash='',[bool]$canReuse=$false){
    $previous=$historyEntries[$key]
    if($canReuse -and $cacheHash -and $previous -and $previous.signature -eq $signature -and $previous.parser -eq $parserFingerprint -and
      $previous.cacheProof -eq (HistoryCacheProof $key $signature $cacheHash $previous.hash)){
      $previousPath=Join-Path $historyDir ($previous.hash+'.json')
      try {
        if((PathKey ([IO.File]::ReadAllText((DiskPath $previousPath)))) -eq $previous.hash){$historyReuse.files++;return}
      }catch{} # A missing/corrupt current-source blob is rebuilt below.
    }
    $json=[ordered]@{schema=1;source=$sourceKey;version=$cacheVersion;parser=$parserFingerprint;events=[object[]]$events}|ConvertTo-Json -Depth 8 -Compress
    $hash=PathKey $json
    # Never replace a blob referenced by the last committed manifest with newer
    # content: another failure later in this refresh must leave it recoverable.
    $path=Join-Path $historyDir ($hash+'.json')
    $valid=$false
    if([IO.File]::Exists((DiskPath $path))){try {$valid=(PathKey ([IO.File]::ReadAllText((DiskPath $path)))) -eq $hash}catch{}}
    if(-not $valid){WriteAtomicText $path $json}
    $entry=[ordered]@{key=$key;signature=$signature;parser=$parserFingerprint;hash=$hash}
    if($cacheHash){$entry.cacheProof=HistoryCacheProof $key $signature $cacheHash $hash}
    $historyEntries[$key]=[pscustomobject]$entry
  }
  function AddSourceEvents([object[]]$events,[bool]$historical){
    # Preserve source order/task boundaries and all 17 identity fields. A moved
    # source's line offsets are deliberately excluded from exact-copy identity.
    [AiUsageEventOpsV1]::AddSource($events,$historical,$eventIdentities,$allEvents,$matchedResponses,{
      param($parts) 'J'+($parts|ConvertTo-Json -Compress)
    })
  }

  if(-not (Test-Path -LiteralPath $cacheDir)){New-Item -ItemType Directory -Path $cacheDir -Force|Out-Null}
  $parserFingerprint=GetParserFingerprint ([IO.File]::ReadAllText($PSCommandPath))
  $compatibleParsers=@($parserFingerprint)
  # Older caches lack actual attribution or per-response consumption records.
  # They must be rebuilt from read-only source logs, never migrated hot.
  $old=@()
  if(Test-Path -LiteralPath $manifestPath){try{$manifestData=Get-Content -Raw $manifestPath|ConvertFrom-Json;if($manifestData.version -eq $cacheVersion -and $manifestData.parser -in $compatibleParsers){$old=@($manifestData.files)}}catch{$old=@()}}
  $oldByPath=@{}
  foreach($entry in $old){if($entry.key){$oldByPath[[string]$entry.key]=$entry}}
  $codexHome=if($SourceRoot){$SourceRoot}elseif($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $HOME '.codex'}
  $canonicalSource=[IO.Path]::GetFullPath($codexHome).TrimEnd('\','/').ToLowerInvariant()
  $sourceKey=PathKey $canonicalSource
  $historyDir=Join-Path (Join-Path $OutputRoot '.codex-usage-dashboard-history') $sourceKey
  $historyManifestPath=Join-Path $historyDir 'manifest.json'
  $historyEntries=@{}
  if([IO.File]::Exists((DiskPath $historyManifestPath))){
    try {
      $historyManifest=[IO.File]::ReadAllText((DiskPath $historyManifestPath))|ConvertFrom-Json
      if($historyManifest.schema -ne 1 -or $historyManifest.source -ne $sourceKey -or $null -eq $historyManifest.PSObject.Properties['files']){throw 'Invalid history manifest'}
      foreach($entry in @($historyManifest.files)){
        if($entry.key -notmatch '^[a-f0-9]{64}$' -or $entry.hash -notmatch '^[a-f0-9]{64}$' -or $entry.parser -notmatch '^[a-f0-9]{64}$' -or $historyEntries.ContainsKey([string]$entry.key)){throw 'Invalid history entry'}
        $historyEntries[[string]$entry.key]=$entry
      }
    }catch{throw 'Historical statistics index is unreadable. Restore the local history backup; the previous dashboard snapshot was kept.'}
  }
  [void][IO.Directory]::CreateDirectory((DiskPath $historyDir))
  $skillHomeParent=Split-Path -Parent ([IO.Path]::GetFullPath($codexHome))
  $skillHomeKey=NormalizeSkillPath $codexHome ''
  $skillHomeParentKey=NormalizeSkillPath $skillHomeParent ''
  $roots=@((Join-Path $codexHome 'sessions'),(Join-Path $codexHome 'archived_sessions'))|?{Test-Path -LiteralPath $_}
  $files=@($roots|%{Get-ChildItem -LiteralPath $_ -Recurse -File -Filter *.jsonl -EA SilentlyContinue})
  MarkPhase 'discovery'
  $allEvents=[Collections.Generic.List[object]]::new();$newManifest=[Collections.Generic.List[object]]::new();$reused=0;$reparsed=0;$matchedResponses=@{}
  $eventIdentities=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $historyReuse=@{files=0}
  $currentKeys=@{};$retainedFiles=0;$recoveredFiles=0;$skippedCaches=0;$historyStart=$null
  [long]$historyBytesRead=0
  foreach($file in $files){$currentKeys[(PathKey $file.FullName)]=$true}
  [long]$sourceBytes=0;[long]$sourceBytesRead=0;[long]$cacheBytesRead=0;[long]$cacheBytes=0;$migrated=0
  foreach($file in $files){
    $path=$file.FullName;$sig=EventSignature $file;$key=PathKey $path;$cache=Join-Path $cacheDir ($key+'.json');$previous=$oldByPath[$key];$events=$null;$rewriteCache=$false;$cacheText=$null
    $sourceBytes+=$file.Length
    if($previous -and [string]$previous.signature -eq $sig -and (Test-Path -LiteralPath $cache)){
      try {
        $cacheBytesRead+=(Get-Item -LiteralPath $cache).Length
        $cacheText=[IO.File]::ReadAllText((DiskPath $cache))
        $cacheData=$cacheText|ConvertFrom-Json
        if($cacheData.version -eq $cacheVersion -and $cacheData.parser -in $compatibleParsers){
          $events=@(ReadStoredEvents $cacheData)
          if($cacheData.parser -ne $parserFingerprint){$rewriteCache=$true;$migrated++}
          $reused++
        }
      } catch {$events=$null}
    }
    if($null -eq $events){
      $events=@(ReadEvents $file)
      $events=@(ReadStoredEvents ([pscustomobject]@{version=$cacheVersion;parser=$parserFingerprint;events=[object[]]$events}))
      $reparsed++
      $sourceBytesRead+=$file.Length
      $rewriteCache=$true
    }
    if($rewriteCache){
      $cacheJson=[ordered]@{version=$cacheVersion;parser=$parserFingerprint;source=$sourceKey;events=[object[]]$events}|ConvertTo-Json -Depth 8 -Compress
      WriteAtomicText $cache $cacheJson
      $cacheText=$cacheJson
    }
    $cacheBytes+=(Get-Item -LiteralPath $cache).Length
    $newManifest.Add([ordered]@{key=$key;signature=$sig;cache=$key})
    SaveHistoryEvents $key $sig $events (PathKey $cacheText) (-not $rewriteCache)
    # Validate response linkage against source order and task boundaries on every
    # aggregation, including warm caches. The extracted r on token_count is only
    # a candidate; identical usage in a later turn cannot cover an older response.
    AddSourceEvents $events $false
  }
  MarkPhase 'currentEvents'
  # Unbound caches predate source isolation. Import only by explicit local
  # request; a changed SourceRoot must never silently pick up another source.
  if($RecoverHistoricalCaches){
    foreach($file in @(Get-ChildItem -LiteralPath $cacheDir -File -Filter '*.json'|Where-Object {$_.BaseName -match '^[a-f0-9]{64}$'})){
      $key=$file.BaseName
      if($currentKeys.ContainsKey($key) -or $historyEntries.ContainsKey($key)){continue}
      try {
        $stored=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json
        if((T $stored source) -and $stored.source -ne $sourceKey){throw 'Different source cache'}
        $events=@(ReadStoredEvents $stored)
      }catch{$skippedCaches++;continue}
      SaveHistoryEvents $key 'recovered' $events
      $recoveredFiles++
    }
  }
  foreach($entry in @($historyEntries.Values|Sort-Object key)){
    if($currentKeys.ContainsKey([string]$entry.key)){continue}
    try {
      $path=Join-Path $historyDir ($entry.hash+'.json')
      $json=[IO.File]::ReadAllText((DiskPath $path))
      if((PathKey $json) -ne $entry.hash){throw 'Historical event integrity mismatch'}
      $stored=$json|ConvertFrom-Json
      if($stored.schema -ne 1 -or $stored.source -ne $sourceKey -or $entry.parser -ne $stored.parser){throw 'Invalid history source'}
      $events=@(ReadStoredEvents $stored)
    }catch{throw 'Historical statistics are unreadable or require a compatible parser. Restore the original logs or local history backup; the previous dashboard snapshot was kept.'}
    $historyBytesRead+=[Text.Encoding]::UTF8.GetByteCount($json)
    $retainedFiles++
    foreach($event in $events){
      if($event.k -in 'token_count','token_usage_record' -and [int64]$event.l[0]+[int64]$event.l[2] -gt 0){
        $date=Day (ParseTimestamp $event.a)
        if(-not $historyStart -or $date -lt $historyStart){$historyStart=$date}
      }
    }
    AddSourceEvents $events $true
  }
  MarkPhase 'historyEvents'
  $manifest=[ordered]@{version=$cacheVersion;parser=$parserFingerprint;source=$sourceKey;generated=([DateTimeOffset]::UtcNow.ToString('o'));files=@($newManifest)}

  $coveredRecordsReleased=[AiUsageEventOpsV1]::ReleaseCoveredRecords($allEvents,$matchedResponses)
  $eventIdentities.Clear();$eventIdentities.TrimExcess()
  $events=$null;$stored=$null;$cacheData=$null;$cacheText=$null;$json=$null
  # Drop temporary JSON/projection/index allocations before the sort, rather
  # than letting background refreshes page those unused objects back from disk.
  [GC]::Collect()
  MarkPhase 'workingMemory'

  $usage=@{};$tasks=@{};$compact=@{};$sn=0;$dupes=0;$supplementalRequests=0;[long]$supplementalTokens=0
  $coveredUsageStates=@{};$seenResponses=@{}
  foreach($event in ($allEvents|Where-Object {$_.k -eq 'token_count'})){
    # A known different response is never interchangeable with a new response,
    # even when a cumulative reset reproduces its old numeric state.
    if(-not $event.provenResponse){
      $state=UsageState $event
      if(-not $coveredUsageStates.ContainsKey($state)){$coveredUsageStates[$state]=[Collections.Generic.List[object]]::new()}
      $coveredUsageStates[$state].Add($event)
    }
  }
  foreach($g in ($allEvents|Where-Object {$_.k -ne 'skill_read'}|Group-Object s)){
    $sn++;$pt='';$pl=''
    foreach($e in ($g.Group|Sort-Object a,i)){
      if($e.k -eq 'thread_settings_applied'){continue}
      $mo=$e.mo;$ef=$e.ef;$scope=$e.sc
      $at=ParseTimestamp $e.a
      if($e.k -in 'token_count','token_usage_record'){
        if($e.k -eq 'token_usage_record'){
          # Response IDs are globally unique. A matched copy covers all duplicates.
          if([int64]$e.l[0]+[int64]$e.l[2] -le 0){continue}
          if($seenResponses.ContainsKey([string]$e.r)){continue};$seenResponses[[string]$e.r]=$true
          if($matchedResponses.ContainsKey([string]$e.r)){continue}
          $legacyCovered=$false
          foreach($candidate in $coveredUsageStates[(UsageState $e)]){
            # In the observed schema the request record precedes its consumption
            # event. A state from an earlier turn/reset cannot cover this request.
            if((ParseTimestamp $candidate.a) -ge $at -and (-not (T $e turn) -or -not (T $candidate turn) -or (T $e turn) -eq (T $candidate turn))){$legacyCovered=$true;break}
          }
          if($legacyCovered){continue}
        }else{
          $tk=(@($e.t)-join '|');$lk=(@($e.l)-join '|')
          if($tk -eq $pt -and $lk -eq $pl){$dupes++;continue}
          $pt=$tk;$pl=$lk
        }
        $inp=[int64]$e.l[0];$ca=[int64]$e.l[1];$ou=[int64]$e.l[2]
        if($inp+$ou -le 0){continue}
        if($e.k -eq 'token_usage_record'){$supplementalRequests++;$supplementalTokens+=$inp+$ou}
        $key=(Day $at)+'|'+$mo+'|'+$ef+'|'+$scope+'|'+$sn
        if(!$usage.ContainsKey($key)){$usage[$key]=[ordered]@{date=(Day $at);model=$mo;effort=$ef;scope=$scope;input=0;cached=0;fresh=0;output=0;reasoning=0;total=0;session=$sn}}
        $z=$usage[$key];$z.input+=$inp;$z.cached+=$ca;$z.fresh+=[Math]::Max(0,$inp-$ca);$z.output+=$ou;$z.reasoning+=[int64]$e.l[3];$z.total+=$inp+$ou
        if($e.turn){
          $taskKey=[string]$e.s+'|'+[string]$e.turn
          if($tasks.ContainsKey($taskKey)){
            $task=$tasks[$taskKey]
            if($task.model -eq 'unknown' -and $mo -ne 'unknown'){$task.model=$mo}
            if($task.effort -eq 'unknown' -and $ef -ne 'unknown'){$task.effort=$ef}
          }
        }
      } elseif($e.k -in 'task_started','task_complete') {
        $key=[string]$e.s+'|'+[string]$e.turn
        if(!$tasks.ContainsKey($key)){$tasks[$key]=[ordered]@{date=(Day $at);startedDate=$null;model=$mo;effort=$ef;scope=$scope;session=$sn;started=$false;completed=$false;duration=$null;ttfb=$null;error=$false}}
        $z=$tasks[$key]
        if($mo -ne 'unknown'){$z.model=$mo};if($ef -ne 'unknown'){$z.effort=$ef}
        if($e.k -eq 'task_started'){
          $z.started=$true
          if(-not $z.startedDate){$z.startedDate=Day $at}
        }else{$z.completed=$true;$z.duration=$e.du;if($e.hf){$z.ttfb=$e.ft};$z.error=$e.er;$z.date=Day $at}
      } elseif($e.k -in 'compacted','context_compacted') {
        $key=[string]$e.s+'|'+[string]$e.w+'|'+$at.ToUnixTimeSeconds()
        if(!$compact.ContainsKey($key)){$compact[$key]=[ordered]@{date=(Day $at);model=$mo;effort=$ef;scope=$scope;session=$sn}}
      }
    }
  }
  MarkPhase 'tokensAndTasks'
  $asOf=if($AsOfDate){[DateTime]::ParseExact($AsOfDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)}else{([DateTimeOffset]::UtcNow.ToOffset($tz)).Date}
  $endDay=$asOf.ToString('yyyy-MM-dd');$start7=$asOf.AddDays(-6).ToString('yyyy-MM-dd');$start30=$asOf.AddDays(-29).ToString('yyyy-MM-dd')
  $skillReads7=@{};$skillReads30=@{};$skillGroups=@{}
  $skillActivity=[Collections.Generic.List[object]]::new();$skillDays=@{};$skillTaskIds=@{};$skillTurnIds=@{}
  foreach($event in ($allEvents|Where-Object {$_.k -eq 'skill_read'})){
    $identity=$event.source+'|'+$event.skill
    $key=$event.s+'|'+$event.turn+'|'+$identity
    $date=Day (ParseTimestamp $event.a)
    if($date -gt $endDay){continue}
    $dayKey=$key+'|'+$date
    if(-not $skillDays.ContainsKey($dayKey)){
      $skillDays[$dayKey]=$true
      if(-not $skillTaskIds.ContainsKey($event.s)){$skillTaskIds[$event.s]=$skillTaskIds.Count+1}
      $turnKey=$event.s+'|'+$event.turn
      if(-not $skillTurnIds.ContainsKey($turnKey)){$skillTurnIds[$turnKey]=$skillTurnIds.Count+1}
      $skillActivity.Add([ordered]@{date=$date;skill=$event.skill;source=$event.source;task=$skillTaskIds[$event.s];turn=$skillTurnIds[$turnKey]})
    }
    if($date -lt $start30){continue}
    if(-not $skillGroups.ContainsKey($identity)){
      $skillGroups[$identity]=@{skill=$event.skill;source=$event.source;readTurns7=0;readTurns30=0;sessions7=@{};sessions30=@{}}
    }
    $group=$skillGroups[$identity]
    if(-not $skillReads30.ContainsKey($key)){$skillReads30[$key]=$true;$group.readTurns30++;$group.sessions30[$event.s]=$true}
    if($date -ge $start7 -and -not $skillReads7.ContainsKey($key)){$skillReads7[$key]=$true;$group.readTurns7++;$group.sessions7[$event.s]=$true}
  }
  $skillRows=@(foreach($group in ($skillGroups.Values|Sort-Object @{Expression='readTurns30';Descending=$true},skill,source)){
    [ordered]@{skill=$group.skill;source=$group.source;readTurns7=$group.readTurns7;tasks7=$group.sessions7.Count;readTurns30=$group.readTurns30;tasks30=$group.sessions30.Count}
  })
  MarkPhase 'skills'
  $metadata=GetSkillMetadata $skillActivity ([IO.Path]::GetFullPath($codexHome))
  MarkPhase 'skillMetadata'
  $skills=[ordered]@{metric='skill_instruction_reads';timeZone='Asia/Shanghai';asOf=$endDay;scope='main_sessions';windows=[ordered]@{days7=[ordered]@{start=$start7;end=$endDay};days30=[ordered]@{start=$start30;end=$endDay}};rows=$skillRows;activitySchema=1;activity=@($skillActivity|Sort-Object date,skill,source,task,turn);metadataSchema=1;metadataAsOf=(Day ([DateTimeOffset]::UtcNow));metadata=$metadata.rows}
  $skills.inventorySchema=1;$skills.inventoryAsOf=Day ([DateTimeOffset]::UtcNow)
  $skills.inventoryScope='known_local_skill_roots';$skills.inventory=$metadata.inventory
  $month=([DateTimeOffset]::UtcNow.ToOffset($tz)).ToString('yyyy-MM')
  $now=([DateTimeOffset]::UtcNow.ToOffset($tz)).ToString('yyyy-MM-dd HH:mm')
  $historyStats=[ordered]@{schema=1;retainedFiles=$retainedFiles;recoveredFiles=$recoveredFiles;skippedCaches=$skippedCaches;startDate=$historyStart}
  $data=[ordered]@{schema=2;usageScopeSchema=1;skills=$skills;generated=$now;month=$month;usage=@($usage.Values);tasks=@($tasks.Values);compactions=@($compact.Values);duplicates=$dupes;refresh=[ordered]@{files=$files.Count;reused=$reused;reparsed=$reparsed;migrated=$migrated;sourceBytes=$sourceBytes;sourceBytesRead=$sourceBytesRead;cacheBytesRead=$cacheBytesRead;cacheBytes=$cacheBytes;elapsedMs=$generationTimer.ElapsedMilliseconds;skillMetadata=$metadata.cost;supplementalTokenRequests=$supplementalRequests;supplementalTokens=$supplementalTokens;history=$historyStats}}
  MarkPhase 'prepareOutput'
  $data.refresh.historyWritesReused=$historyReuse.files
  $data.refresh.coveredRecordsReleased=$coveredRecordsReleased
  $data.refresh.phaseMs=$phaseTimes
  $data.refresh.elapsedMs=$generationTimer.ElapsedMilliseconds
  $dataJson=$data|ConvertTo-Json -Depth 10 -Compress

  $webRoot=Join-Path $PSScriptRoot 'web'
  $html=[IO.File]::ReadAllText((Join-Path $webRoot 'dashboard.html'))
  $css=[IO.File]::ReadAllText((Join-Path $webRoot 'dashboard.css'))
  $js=[IO.File]::ReadAllText((Join-Path $webRoot 'dashboard.js'))
  $skillChinese=[IO.File]::ReadAllText((Join-Path $webRoot 'skill-descriptions.zh-CN.js'))
  $html=$html.Replace('/*__DASHBOARD_CSS__*/',$css).Replace('//__SKILL_DESCRIPTIONS_ZH__',$skillChinese).Replace('//__DASHBOARD_JS__',$js)
  $uiContractMarkers=@('dashboard-ui-contract-v1','Token 构成占比','模型 Token 占比','推理强度 Token 占比','Reasoning 为 Output 子集','dashboard-skill-contract-v1','Skill 说明读取','不代表实际调用或任务成功')
  foreach($marker in $uiContractMarkers){if(-not $html.Contains($marker)){throw "Dashboard UI contract missing: $marker"}}
  # Commit the data last: the service publishes it only after a successful exit.
  WriteAtomicText $out $html
  WriteAtomicText $historyManifestPath ([ordered]@{schema=1;source=$sourceKey;files=@($historyEntries.Values|Sort-Object key)}|ConvertTo-Json -Depth 5 -Compress)
  WriteAtomicText $manifestPath ($manifest|ConvertTo-Json -Depth 5 -Compress)
  WriteAtomicText $dataOut $dataJson
  [ordered]@{status='ready';files=$files.Count;reused=$reused;reparsed=$reparsed;cacheVersion=$cacheVersion}|ConvertTo-Json -Compress
} finally {if($m){$m.ReleaseMutex()|Out-Null;$m.Dispose()}}
