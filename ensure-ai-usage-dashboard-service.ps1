# One-shot service check used by the scheduled maintenance task.
[CmdletBinding()]
param(
  [ValidateRange(1,65535)][int]$Port=8765
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$serviceScript=Join-Path $root 'start-ai-usage-dashboard-service.ps1'
$pwsh=Get-Command pwsh -ErrorAction SilentlyContinue
$shell=if($pwsh){$pwsh.Source}else{'powershell.exe'}
function Test-Listening {
  $client=$null
  try {
    $client=[Net.Sockets.TcpClient]::new()
    $client.Connect('127.0.0.1',$Port)
    return $true
  } catch { return $false }
  finally { if($client){$client.Dispose()} }
}
if(Test-Listening){exit 0}
if(-not (Test-Path -LiteralPath $serviceScript)){exit 2}
Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$serviceScript) -WindowStyle Hidden | Out-Null
for($i=0;$i -lt 30;$i++){
  Start-Sleep -Milliseconds 250
  if(Test-Listening){exit 0}
}
exit 1
