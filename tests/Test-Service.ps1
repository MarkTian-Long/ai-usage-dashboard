[CmdletBinding()]
param(
  [string]$ServiceScript='',
  [string]$ServiceHost='pwsh',
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
    $state=Read-Status
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
$mode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'mode.txt'))
Start-Sleep -Milliseconds 650
if($mode -eq 'nochange'){exit 0}
$data=Join-Path $PSScriptRoot 'codex-usage-dashboard-data.json'
if($mode -eq 'invalid'){[IO.File]::WriteAllText($data,'not json');exit 0}
[IO.File]::WriteAllText($data,('{"synthetic":true,"version":"'+$mode+'"}'))
if($mode -eq 'fail'){exit 7}
exit 0
'@
  [IO.File]::WriteAllText((Join-Path $fixture 'refresh-ai-usage-dashboard.ps1'),$mock)
  $shell=(Get-Command $ServiceHost -ErrorAction Stop).Source
  $launchScript=$ServiceScript
  if($UseDefaultRoot){
    $launchScript=Join-Path $fixture 'isolated-service.ps1'
    Copy-Item -LiteralPath $ServiceScript -Destination $launchScript
  }
  $serviceArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$launchScript+'"'),'-Port',$port,'-RequestTimeoutMs',400,'-MaxHeaderBytes',1024)
  if(-not $UseDefaultRoot){$serviceArguments+=@('-Root',('"'+$fixture+'"'))}
  $serviceProcess=Start-Process -FilePath $shell -ArgumentList $serviceArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $fixture 'stdout.log') -RedirectStandardError (Join-Path $fixture 'stderr.log')
  $null=$serviceProcess.Handle
  $initial=$null
  for($i=0;$i -lt 30;$i++) {
    try {$initial=Read-Status;break} catch {if($serviceProcess.HasExited){throw ('Synthetic service exited before startup: '+[IO.File]::ReadAllText((Join-Path $fixture 'stderr.log')))};Start-Sleep -Milliseconds 100}
  }
  Assert-Test ($null -ne $initial -and $initial.status -eq 'ready') 'Existing valid snapshot starts ready'
  Assert-Test ((Invoke-Http -Uri ($url+'/')).StatusCode -eq 200) 'Dashboard route remains available'
  $unauthorized=Invoke-Http -Uri ($url+'/api/refresh') -Method Post
  Assert-Test ($unauthorized.StatusCode -eq 405) 'Refresh still requires the dashboard header'

  [IO.File]::WriteAllText((Join-Path $fixture 'mode.txt'),'fail')
  Assert-Test ((Request-Refresh).StatusCode -eq 202) 'Refresh is accepted'
  Assert-Test ((Request-Refresh).StatusCode -eq 409) 'Concurrent refresh returns busy'
  $failed=Wait-Refresh
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
  [ordered]@{passed=$true;serviceHost=$shell;usedDefaultRoot=[bool]$UseDefaultRoot;count=$results.Count;results=$results}|ConvertTo-Json -Depth 4
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
