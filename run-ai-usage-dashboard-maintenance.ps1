# One-shot user-level maintenance invoked by Windows Task Scheduler each minute.
# The generator reads local Codex JSONL; this script only uses the loopback API.
[CmdletBinding()]
param([switch]$ForceRefresh)

$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$ensure=Join-Path $root 'ensure-ai-usage-dashboard-service.ps1'
$dataPath=Join-Path $root 'codex-usage-dashboard-data.json'
$log=Join-Path $root 'codex-usage-dashboard-maintenance.log'
$mutex=[Threading.Mutex]::new($false,'Local\CodexUsageDashboardMaintenance')
$acquired=$false
try {$acquired=$mutex.WaitOne(0)}
catch [Threading.AbandonedMutexException] {$acquired=$true}
if(-not $acquired){$mutex.Dispose();exit 0}

function Write-MaintenanceLog([string]$Message){
  try {Add-Content -LiteralPath $script:log -Value (([DateTime]::UtcNow.ToString('o'))+' '+$Message) -Encoding UTF8 -ErrorAction Stop}
  catch {Write-Warning ('Dashboard maintenance log could not be written: '+$_.Exception.Message)}
}
function Get-ServiceStatus(){
  Invoke-RestMethod -Uri 'http://127.0.0.1:8765/api/status' -TimeoutSec 5
}
function Request-ServiceRefresh(){
  try {return [int](Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8765/api/refresh' -Method Post -Headers @{'X-Codex-Dashboard'='1'} -TimeoutSec 5).StatusCode}
  catch {if($_.Exception.Response){return [int]$_.Exception.Response.StatusCode};throw}
}

try {
  if(-not (Test-Path -LiteralPath $ensure -PathType Leaf)){throw 'Service check script is missing.'}
  & $ensure
  if($LASTEXITCODE -ne 0){throw ('Service check exited '+$LASTEXITCODE)}
  $before=Get-ServiceStatus
  $now=Get-Date
  $hour=$now.ToString('yyyyMMddHH')
  $data=Get-Item -LiteralPath $dataPath -ErrorAction SilentlyContinue
  $diskVersion=if($data){[string]$data.LastWriteTimeUtc.Ticks}else{''}
  $diskHour=if($data){$data.LastWriteTime.ToString('yyyyMMddHH')}else{''}
  $due=$ForceRefresh -or $before.status -eq 'failed' -or $diskHour -ne $hour -or [string]$before.updated -ne $diskVersion
  if(-not $due){exit 0}

  $response=Request-ServiceRefresh
  if($response -notin 202,409){throw ('Refresh returned HTTP '+$response)}
  Write-MaintenanceLog ('refresh accepted hour='+$hour+' http='+$response)
  $committed=$false
  for($attempt=0;$attempt -lt 180;$attempt++){
    Start-Sleep -Seconds 1
    $status=Get-ServiceStatus
    if($status.status -eq 'failed'){throw ('Service refresh failed: '+$status.lastError)}
    if($status.status -ne 'ready' -or -not $status.updated -or [string]$status.updated -eq [string]$before.updated){continue}
    $current=Get-Item -LiteralPath $dataPath -ErrorAction Stop
    if([string]$status.updated -eq [string]$current.LastWriteTimeUtc.Ticks){$committed=$true;break}
  }
  if(-not $committed){throw 'Refresh did not publish a matching data version within 180 seconds.'}
  Write-MaintenanceLog ('refresh committed hour='+$hour+' version='+$status.updated)
} catch {
  Write-MaintenanceLog ('maintenance failed: '+$_.Exception.Message)
  exit 1
} finally {
  $mutex.ReleaseMutex()|Out-Null
  $mutex.Dispose()
}
