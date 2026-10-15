[CmdletBinding()]
param(
  [string]$ServiceScript='',
  [string]$ServiceHost='pwsh',
  [string]$RefreshHost='',
  [switch]$BelowNormalLaunch,
  [switch]$UseDefaultRoot,
  [string]$TestOutputRoot=(Join-Path ([IO.Path]::GetTempPath()) 'codex-dashboard-service-tests')
)
$ErrorActionPreference='Stop'
if(-not $ServiceScript){$ServiceScript=Join-Path (Split-Path -Parent $PSScriptRoot) 'start-ai-usage-dashboard-service.ps1'}
$testRoot=[IO.Path]::GetFullPath($TestOutputRoot)
$fixture=[IO.Path]::GetFullPath((Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $fixture -Force|Out-Null
$serviceProcess=$null
$sockets=[Collections.Generic.List[Net.Sockets.TcpClient]]::new()
$results=[Collections.Generic.List[object]]::new()
$performance=[ordered]@{}
$refreshStatusMaxMs=0
function Assert-Test([bool]$Condition,[string]$Name) {
  $results.Add([pscustomobject]@{name=$Name;passed=$Condition})
  if(-not $Condition){throw ('Assertion failed: '+$Name)}
}
function Read-Status {Invoke-RestMethod -Uri ($url+'/api/status') -TimeoutSec 3}
function Invoke-Http([string]$Uri,[string]$Method='GET',[hashtable]$Headers=$null) {
  $parameters=@{Uri=$Uri;Method=$Method;TimeoutSec=3;UseBasicParsing=$true}
  if($Headers){$parameters.Headers=$Headers}
  try {$response=Invoke-WebRequest @parameters;return [pscustomobject]@{StatusCode=[int]$response.StatusCode}}
  catch {
    if($_.Exception.Response){return [pscustomobject]@{StatusCode=[int]$_.Exception.Response.StatusCode}}
    throw
  }
}
function Wait-Refresh {
  for($i=0;$i -lt 100;$i++) {
    $statusWatch=[Diagnostics.Stopwatch]::StartNew()
    $state=Read-Status
    $statusWatch.Stop();$script:refreshStatusMaxMs=[Math]::Max($script:refreshStatusMaxMs,$statusWatch.ElapsedMilliseconds)
    if($state.status -ne 'refreshing'){return $state}
    Start-Sleep -Milliseconds 50
  }
  throw 'Synthetic refresh did not finish in time.'
}
function Request-Refresh {
  Invoke-Http -Uri ($url+'/api/refresh') -Method Post -Headers @{'X-Codex-Dashboard'='1'}
}
try {
  $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
  Assert-Test ($port -ne 8765) 'Production port is excluded'
  $url='http://127.0.0.1:'+$port
  [IO.File]::WriteAllText((Join-Path $fixture 'codex-usage-dashboard.html'),'<html><title>Synthetic fixture</title></html>')
  [IO.File]::WriteAllText((Join-Path $fixture 'codex-usage-dashboard-data.json'),'{"synthetic":true,"version":"initial"}')
  $mock=@'
$ErrorActionPreference='Stop'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'refresh-child.pid'),[string]$PID)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'refresh-engine.txt'),(Get-Process -Id $PID).Path)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'refresh-priority.txt'),[string](Get-Process -Id $PID).PriorityClass)
$mode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt'))
Start-Sleep -Milliseconds 650
if($mode -eq 'nochange'){exit 0}
$data=Join-Path $PSScriptRoot 'codex-usage-dashboard-data.json'
if($mode -eq 'invalid'){[IO.File]::WriteAllText($data,'not json');exit 0}
if($mode -eq 'large'){
  $rows=('{"date":"2026-10-15","model":"synthetic-model","total":123456},'*12000).TrimEnd(',')
  [IO.File]::WriteAllText($data,('{"synthetic":true,"version":"large","rows":['+$rows+']}'))
  exit 0
}
[IO.File]::WriteAllText($data,('{"synthetic":true,"version":"'+$mode+'"}'))
if($mode -eq 'fail'){exit 7}
exit 0
'@
  [IO.File]::WriteAllText((Join-Path $fixture 'refresh-ai-usage-dashboard.ps1'),$mock)
  $shell=(Get-Command $ServiceHost -ErrorAction Stop).Source
  $expectedRefreshShell=$null
  if($RefreshHost){
    $expectedRefreshShell=(Get-Command $RefreshHost -ErrorAction Stop).Source
    $settings="@{ SourceRoot = ''; PowerShellPath = '"+$expectedRefreshShell.Replace("'","''")+"' }"
    [IO.File]::WriteAllText((Join-Path $fixture 'codex-usage-dashboard.local.psd1'),$settings,[Text.UTF8Encoding]::new($false))
  }
  $launchScript=$ServiceScript
  if($UseDefaultRoot){
    $launchScript=Join-Path $fixture 'isolated-service.ps1'
    Copy-Item -LiteralPath $ServiceScript -Destination $launchScript
  }
  if($BelowNormalLaunch){
    $targetScript=$launchScript
    $launchScript=Join-Path $fixture 'below-normal-launch.ps1'
    $wrapper="param(`$Port,`$Root,`$RequestTimeoutMs,`$MaxHeaderBytes)`n[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'`n& '"+$targetScript.Replace("'","''")+"' @PSBoundParameters"
    [IO.File]::WriteAllText($launchScript,$wrapper,[Text.UTF8Encoding]::new($true))
  }
  $serviceArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$launchScript+'"'),'-Port',$port,'-RequestTimeoutMs',400,'-MaxHeaderBytes',1024)
  if(-not $UseDefaultRoot){$serviceArguments+=@('-Root',('"'+$fixture+'"'))}
  $serviceProcess=Start-Process -FilePath $shell -ArgumentList $serviceArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.log') -RedirectStandardError (Join-Path $fixture 'stderr.log')
  $null=$serviceProcess.Handle
  $initial=$null;$startupError=''
  for($i=0;$i -lt 30;$i++) {
    try {$initial=Read-Status;break} catch {$startupError=[string]$_;if($serviceProcess.HasExited){throw ('Synthetic service exited before startup: '+[IO.File]::ReadAllText((Join-Path $fixture 'stderr.log')))};Start-Sleep -Milliseconds 100}
  }
  if($null -eq $initial){throw ('Synthetic service did not answer: '+$startupError)}
  Assert-Test ($null -ne $initial -and $initial.status -eq 'ready') 'Existing valid snapshot starts ready'
  if($BelowNormalLaunch){Assert-Test ((Get-Process -Id $serviceProcess.Id).PriorityClass -eq 'Normal') 'A scheduled BelowNormal launcher does not leave the HTTP service below normal priority'}
  Assert-Test ((Invoke-Http -Uri ($url+'/')).StatusCode -eq 200) 'Dashboard route remains available'
  $unauthorized=Invoke-Http -Uri ($url+'/api/refresh') -Method Post
  Assert-Test ($unauthorized.StatusCode -eq 405) 'Refresh still requires the dashboard header'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'fail')
  Assert-Test ((Request-Refresh).StatusCode -eq 202) 'Refresh is accepted'
  Assert-Test ((Request-Refresh).StatusCode -eq 409) 'Concurrent refresh returns busy'
  $failed=Wait-Refresh
  if($expectedRefreshShell){Assert-Test ([StringComparer]::OrdinalIgnoreCase.Equals([IO.File]::ReadAllText((Join-Path $fixture 'refresh-engine.txt')),$expectedRefreshShell)) 'The local configuration selects the actual refresh executable'}
  if($BelowNormalLaunch){Assert-Test ([IO.File]::ReadAllText((Join-Path $fixture 'refresh-priority.txt')) -eq 'Normal') 'Refresh children inherit ordinary priority from the HTTP service'}
  Assert-Test ($failed.status -eq 'failed' -and $failed.exitCode -eq 7 -and $failed.lastError) 'Nonzero refresh exit reports failure'
  Assert-Test ($failed.updated -eq $initial.updated) 'Failure preserves committed version'
  $data=Invoke-RestMethod -Uri ($url+'/api/data') -TimeoutSec 3
  Assert-Test ($data.version -eq 'initial') 'Failure preserves last successful data despite a changed disk file'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'nochange')
  Assert-Test ((Request-Refresh).StatusCode -eq 202) 'A failed refresh can be retried'
  $unchanged=Wait-Refresh
  Assert-Test ($unchanged.status -eq 'failed' -and $unchanged.exitCode -eq 0 -and $unchanged.updated -eq $initial.updated) 'Exit zero without a new version remains failed'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'invalid')
  Request-Refresh|Out-Null
  $invalid=Wait-Refresh
  Assert-Test ($invalid.status -eq 'failed' -and $invalid.updated -eq $initial.updated) 'Malformed data cannot replace the committed snapshot'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'success')
  Request-Refresh|Out-Null
  $success=Wait-Refresh
  Assert-Test ($success.status -eq 'ready' -and $success.exitCode -eq 0 -and $null -eq $success.lastError -and $success.updated -ne $initial.updated) 'A successful new snapshot clears the error and advances its version'
  $data=Invoke-RestMethod -Uri ($url+'/api/data') -TimeoutSec 3
  Assert-Test ($data.version -eq 'success') 'Successful snapshot becomes visible'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'large')
  $refreshStatusMaxMs=0
  Request-Refresh|Out-Null
  $largeReady=Wait-Refresh
  Assert-Test ($largeReady.status -eq 'ready' -and $largeReady.updated -ne $success.updated) 'A large valid JSON snapshot advances atomically'
  $transferWatch=[Diagnostics.Stopwatch]::StartNew()
  $largeResponse=Invoke-WebRequest -Uri ($url+'/api/data') -TimeoutSec 10 -UseBasicParsing
  $transferWatch.Stop()
  $largeData=ConvertFrom-Json -InputObject $largeResponse.Content
  Assert-Test ($largeData.version -eq 'large' -and @($largeData.rows).Count -eq 12000) 'Large committed data is transmitted completely'
  $performance.largeSnapshot=[ordered]@{bytes=[Text.Encoding]::UTF8.GetByteCount($largeResponse.Content);maxStatusMs=$refreshStatusMaxMs;dataTransferMs=$transferWatch.ElapsedMilliseconds}

  # Incomplete/speculative sockets must not serialize their deadlines ahead of
  # a ready browser request. The old one-client loop exceeded the HTTP deadline
  # after this bounded queue of 400ms header waits.
  $incomplete=[Collections.Generic.List[Net.Sockets.TcpClient]]::new()
  for($index=0;$index -lt 12;$index++){
    $socket=[Net.Sockets.TcpClient]::new();$sockets.Add($socket);$incomplete.Add($socket)
    $socket.Connect('127.0.0.1',$port);$socket.GetStream().ReadTimeout=3000
    if($index -gt 0){
      $prefix=[Text.Encoding]::ASCII.GetBytes("GET /api/status HTTP/1.1`r`nHost: localhost`r`n")
      $socket.GetStream().Write($prefix,0,$prefix.Length)
    }
  }
  $queueWatch=[Diagnostics.Stopwatch]::StartNew();$responsive=Read-Status;$queueWatch.Stop()
  Assert-Test ($responsive.status -eq 'ready') 'Ready requests proceed while multiple header deadlines remain pending'
  foreach($socket in $incomplete){
    $reader=[IO.StreamReader]::new($socket.GetStream());$line=$reader.ReadLine();$reader.Dispose();$socket.Dispose()
    Assert-Test ($line -match '^HTTP/1.1 408 ') 'Every incomplete or idle connection retains its total header deadline'
  }
  $performance.incompleteQueue=[ordered]@{connections=$incomplete.Count;statusMs=$queueWatch.ElapsedMilliseconds}

  $partial=[Net.Sockets.TcpClient]::new();$sockets.Add($partial);$partial.Connect('127.0.0.1',$port)
  $partialStream=$partial.GetStream();$partialStream.ReadTimeout=3000
  $bytes=[Text.Encoding]::ASCII.GetBytes("GET /api/status HTTP/1.1`r`nHost: localhost`r`n")
  $partialStream.Write($bytes,0,$bytes.Length)
  $watch=[Diagnostics.Stopwatch]::StartNew();$recovered=Read-Status;$watch.Stop()
  $reader=[IO.StreamReader]::new($partialStream)
  $timeoutLine=$reader.ReadLine();$reader.Dispose();$partial.Dispose()
  Assert-Test ($timeoutLine -match '^HTTP/1.1 408 ' -and $recovered.status -eq 'ready' -and $watch.ElapsedMilliseconds -lt 3000) 'Incomplete headers time out and the next request recovers'

  $large=[Net.Sockets.TcpClient]::new();$sockets.Add($large);$large.Connect('127.0.0.1',$port)
  $largeStream=$large.GetStream();$largeStream.ReadTimeout=3000
  $bytes=[Text.Encoding]::ASCII.GetBytes("GET / HTTP/1.1`r`nX-Large: "+('a'*1500)+"`r`n`r`n")
  $largeStream.Write($bytes,0,$bytes.Length)
  $reader=[IO.StreamReader]::new($largeStream);$limitLine=$reader.ReadLine();$reader.Dispose();$large.Dispose()
  Assert-Test ($limitLine -match '^HTTP/1.1 431 ') 'Oversized headers are rejected'
  Assert-Test ((Read-Status).status -eq 'ready') 'Service remains available after the header limit'
  Assert-Test (Test-Path -LiteralPath (Join-Path $fixture 'codex-usage-dashboard-service.log')) 'Controlled local refresh log is written'
  [ordered]@{passed=$true;serviceHost=$shell;usedDefaultRoot=[bool]$UseDefaultRoot;count=$results.Count;performance=$performance;results=$results}|ConvertTo-Json -Depth 5
} finally {
  foreach($socket in $sockets){$socket.Dispose()}
  if($serviceProcess -and -not $serviceProcess.HasExited){Stop-Process -Id $serviceProcess.Id -Force}
  # Only stop the bounded synthetic child whose command line names this fixture.
  $childFile=Join-Path $fixture 'refresh-child.pid'
  if(Test-Path -LiteralPath $childFile){
    $childId=0
    if([int]::TryParse([IO.File]::ReadAllText($childFile),[ref]$childId)){
      $child=Get-CimInstance Win32_Process -Filter ('ProcessId = '+$childId) -ErrorAction SilentlyContinue
      if($child -and $child.CommandLine -and $child.CommandLine.Contains($fixture)){Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue}
    }
  }
  if($fixture.StartsWith($testRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and $fixture -ne $testRoot){
    Remove-Item -LiteralPath $fixture -Recurse -Force
  }
}
