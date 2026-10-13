# Manual aggregate-refresh entry point; automatic maintenance uses the service API.
[CmdletBinding()]
param([string]$SourceRoot='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceRoot)){
  $localConfig=Join-Path $PSScriptRoot 'codex-usage-dashboard.local.psd1'
  if(Test-Path -LiteralPath $localConfig){
    try {$SourceRoot=[string](Import-PowerShellDataFile -LiteralPath $localConfig).SourceRoot}
    catch {throw "Invalid local dashboard configuration: $localConfig"}
  }
  if([string]::IsNullOrWhiteSpace($SourceRoot)){
    $SourceRoot=if($env:CODEX_HOME){$env:CODEX_HOME}else{Join-Path $HOME '.codex'}
  }
}
& (Join-Path $PSScriptRoot 'refresh-ai-usage-dashboard.ps1') -SourceRoot $SourceRoot -OutputRoot $PSScriptRoot
exit $LASTEXITCODE
