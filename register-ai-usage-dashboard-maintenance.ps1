# Register one short-lived, user-level maintenance run each minute.
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference='Stop'
$name='Codex Usage Dashboard Maintenance'
if($Remove){
  & schtasks.exe /Delete /TN $name /F | Out-Null
  if($LASTEXITCODE -ne 0){throw 'Maintenance task removal failed.'}
  exit 0
}
$script=Join-Path $PSScriptRoot 'run-ai-usage-dashboard-maintenance.ps1'
if(-not (Test-Path -LiteralPath $script -PathType Leaf)){throw 'Maintenance script is missing.'}
$launcher=Join-Path $PSScriptRoot 'tools\run-dashboard-maintenance-hidden.vbs'
if(-not (Test-Path -LiteralPath $launcher -PathType Leaf)){throw 'Hidden maintenance launcher is missing.'}
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$action='wscript.exe //B //Nologo "'+$launcher+'"'
if($action.Length -gt 261){throw 'Maintenance task action exceeds the Windows length limit.'}
& schtasks.exe /Create /TN $name /SC MINUTE /MO 1 /ST 00:00 /RU $user /IT /RL LIMITED /TR $action /F | Out-Null
if($LASTEXITCODE -ne 0){throw 'Maintenance task registration failed.'}
# The schtasks defaults suppress runs on battery power and can stop a run
# mid-refresh when AC is unplugged. A laptop must recover in either state.
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
Set-ScheduledTask -TaskName $name -Settings $settings | Out-Null
& schtasks.exe /Run /TN $name | Out-Null
if($LASTEXITCODE -ne 0){throw 'Maintenance task start failed.'}
