# Local-only HTTP server for the Codex usage dashboard.
[CmdletBinding()]
param(
  [ValidateRange(1,65535)][int]$Port=8765,
  [string]$Root='',
  [string]$SourceRoot='',
  [ValidateRange(100,60000)][int]$RequestTimeoutMs=5000,
  [ValidateRange(1024,65536)][int]$MaxHeaderBytes=16384
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Root)){$Root=$PSScriptRoot}
$Dashboard=Join-Path $Root 'codex-usage-dashboard.html'
$Data=Join-Path $Root 'codex-usage-dashboard-data.json'
$Refresh=Join-Path $Root 'refresh-ai-usage-dashboard.ps1'
if([string]::IsNullOrWhiteSpace($SourceRoot)){
  $localConfig=Join-Path $Root 'codex-usage-dashboard.local.psd1'
  if(Test-Path -LiteralPath $localConfig){
    try {$SourceRoot=[string](Import-PowerShellDataFile -LiteralPath $localConfig).SourceRoot}
    catch {throw "Invalid local dashboard configuration: $localConfig"}
  }
  if([string]::IsNullOrWhiteSpace($SourceRoot)){
    $SourceRoot=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $HOME '.codex'}
  }
}
$Log=Join-Path $Root 'codex-usage-dashboard-service.log'
$RefreshProcess=$null
$RefreshState='failed'
$LastError='Dashboard data is not ready. Run a refresh.'
$LastExitCode=$null
$CommittedData=$null
$CommittedUpdated='0'
$RefreshStartVersion='0'
$pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
$RefreshShell=if($pwsh){$pwsh.Source}else{'powershell.exe'}
function Write-ServiceLog([string]$Message) {
  # Only controlled messages and exit codes are logged; never source records.
  try {Add-Content -LiteralPath $Log -Value (([DateTime]::UtcNow.ToString('o'))+' '+$Message) -Encoding UTF8} catch {}
}
function Send-Response($Stream,[int]$Code,[string]$Type,[byte[]]$Body) {
  $reasons=@{200='OK';202='Accepted';400='Bad Request';404='Not Found';405='Method Not Allowed';408='Request Timeout';409='Conflict';431='Request Header Fields Too Large';500='Internal Server Error'}
  $reason=$reasons[$Code]
  $nl="`r`n"
  $head="HTTP/1.1 $Code $reason$nl"+"Content-Type: $Type; charset=utf-8$nl"+"Content-Length: $($Body.Length)$nl"+"Cache-Control: no-store$nl"+"Connection: close$nl$nl"
  $bytes=[Text.Encoding]::ASCII.GetBytes($head)
  $Stream.Write($bytes,0,$bytes.Length);$Stream.Write($Body,0,$Body.Length)
}
function Send-Json($Stream,[int]$Code,$Value) {
  Send-Response $Stream $Code 'application/json' ([Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Compress)))
}
function Get-SharedFileBytes([string]$Path) {
  for($attempt=1;$attempt -le 5;$attempt++) {
    try {
      $share=[System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      $file=[System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,$share)
      try {$memory=[System.IO.MemoryStream]::new();try {$file.CopyTo($memory);return ,$memory.ToArray()} finally {$memory.Dispose()}} finally {$file.Dispose()}
    } catch [System.IO.IOException] {
      if($attempt -eq 5) {throw}
      Start-Sleep -Milliseconds 80
    }
  }
}
function Get-DataVersion {
  if(Test-Path -LiteralPath $Data){return [string][IO.File]::GetLastWriteTimeUtc($Data).Ticks}
  return '0'
}
function Read-DataSnapshot {
  $version=Get-DataVersion
  $bytes=Get-SharedFileBytes $Data
  if($version -eq '0' -or $version -ne (Get-DataVersion)){throw 'Data changed while loading.'}
  [Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop|Out-Null
  return [pscustomobject]@{Bytes=$bytes;Updated=$version}
}
function Set-RefreshFailure([string]$Message) {
  $script:RefreshState='failed'
  $script:LastError=$Message+' See codex-usage-dashboard-service.log.'
  Write-ServiceLog $Message
}
function Update-RefreshStatus {
  if(-not $script:RefreshProcess -or -not $script:RefreshProcess.HasExited){return}
  try {
    $script:RefreshProcess.WaitForExit()
    $code=$script:RefreshProcess.ExitCode
    if($null -eq $code){throw 'Refresh exit code is unavailable.'}
    $script:LastExitCode=[int]$code
    if($code -ne 0){Set-RefreshFailure ('Refresh exited with code '+$code+'.');return}
    $snapshot=Read-DataSnapshot
    if($snapshot.Updated -eq $script:RefreshStartVersion -or $snapshot.Updated -eq $script:CommittedUpdated){
      Set-RefreshFailure 'Refresh produced no new data snapshot.';return
    }
    $script:CommittedData=$snapshot.Bytes
    $script:CommittedUpdated=$snapshot.Updated
    $script:RefreshState='ready'
    $script:LastError=$null
    Write-ServiceLog ('Refresh succeeded; data version '+$snapshot.Updated+'.')
  } catch {Set-RefreshFailure 'Refresh could not publish a valid data snapshot.'}
  finally {$script:RefreshProcess.Dispose();$script:RefreshProcess=$null}
}
function Get-Status {
  $value=[ordered]@{status=$script:RefreshState;updated=$script:CommittedUpdated;lastError=$script:LastError}
  if($null -ne $script:LastExitCode){$value.exitCode=$script:LastExitCode}
  return $value
}
function Read-RequestHeaders($Stream) {
  # The deadline covers the entire header, so partial or trickled requests
  # cannot hold the single local request handler indefinitely.
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $bytes=[Collections.Generic.List[byte]]::new()
  while($bytes.Count -lt $MaxHeaderBytes) {
    $remaining=$RequestTimeoutMs-[int]$watch.ElapsedMilliseconds
    if($remaining -le 0){return [pscustomobject]@{Code=408;Text=$null}}
    $Stream.ReadTimeout=[Math]::Max(1,$remaining)
    try {$next=$Stream.ReadByte()} catch {return [pscustomobject]@{Code=408;Text=$null}}
    if($next -lt 0){return [pscustomobject]@{Code=400;Text=$null}}
    $bytes.Add([byte]$next)
    $n=$bytes.Count
    if($n -ge 4 -and $bytes[$n-4] -eq 13 -and $bytes[$n-3] -eq 10 -and $bytes[$n-2] -eq 13 -and $bytes[$n-1] -eq 10){
      return [pscustomobject]@{Code=200;Text=[Text.Encoding]::ASCII.GetString($bytes.ToArray())}
    }
  }
  return [pscustomobject]@{Code=431;Text=$null}
}
try {
  $snapshot=Read-DataSnapshot
  $CommittedData=$snapshot.Bytes;$CommittedUpdated=$snapshot.Updated
  $RefreshState='ready';$LastError=$null
} catch {Write-ServiceLog 'No valid existing data snapshot; a refresh is required.'}
$listener=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$listener.Start()
try {
  while($true) {
    $client=$listener.AcceptTcpClient()
    $stream=$null
    try {
      $stream=$client.GetStream();$stream.WriteTimeout=$RequestTimeoutMs
      $request=Read-RequestHeaders $stream
      if($request.Code -ne 200){Send-Response $stream $request.Code 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Invalid or incomplete request headers'));continue}
      $lines=$request.Text -split "`r`n"
      if($lines[0] -notmatch '^([A-Z]+) ([^\s]+) HTTP/1\.[01]$'){
        Send-Response $stream 400 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Invalid request line'));continue
      }
      $method=$Matches[1];$path=$Matches[2].Split('?')[0]
      $headers=@{}
      foreach($line in $lines[1..($lines.Count-1)]){
        if($line -eq ''){break}
        $i=$line.IndexOf(':')
        if($i -gt 0){$headers[$line.Substring(0,$i).ToLowerInvariant()]=$line.Substring($i+1).Trim()}
      }
      Update-RefreshStatus
      if($method -eq 'GET' -and $path -eq '/') {
        if(Test-Path -LiteralPath $Dashboard){Send-Response $stream 200 'text/html' (Get-SharedFileBytes $Dashboard)}else{Send-Response $stream 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Dashboard not ready'))}
      } elseif($method -eq 'GET' -and $path -eq '/api/data') {
        if($null -ne $CommittedData){Send-Response $stream 200 'application/json' $CommittedData}else{Send-Json $stream 404 @{error='data not ready'}}
      } elseif($method -eq 'GET' -and $path -eq '/api/status') {
        Send-Json $stream 200 (Get-Status)
      } elseif($method -eq 'POST' -and $path -eq '/api/refresh' -and $headers['x-codex-dashboard'] -eq '1') {
        if($RefreshProcess){Send-Json $stream 409 @{status='busy'}}
        else {
          $RefreshStartVersion=Get-DataVersion
          $LastExitCode=$null
          $started=$false
          try {
            $RefreshProcess=Start-Process -FilePath $RefreshShell -ArgumentList @('-NoProfile','-File',('"'+$Refresh+'"'),'-SourceRoot',('"'+$SourceRoot+'"'),'-OutputRoot',('"'+$Root+'"')) -PassThru -WindowStyle Hidden
            # Retain the process handle so ExitCode remains available after exit.
            $null=$RefreshProcess.Handle
            $RefreshState='refreshing';$LastError=$null
            Write-ServiceLog 'Refresh started.'
            $started=$true
          } catch {
            Set-RefreshFailure 'Refresh could not start.'
          }
          if($started){Send-Json $stream 202 (Get-Status)}else{Send-Json $stream 500 (Get-Status)}
        }
      } else {Send-Response $stream 405 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Method not allowed'))}
    } catch {
      Write-ServiceLog 'A local HTTP request could not be completed.'
      try{if($stream){Send-Response $stream 500 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Local service error'))}}catch{}
    } finally {if($stream){$stream.Dispose()};$client.Dispose()}
  }
} finally {$listener.Stop();if($RefreshProcess){$RefreshProcess.Dispose()}}
