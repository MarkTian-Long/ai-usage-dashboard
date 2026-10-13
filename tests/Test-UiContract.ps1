[CmdletBinding()]
param([string]$DashboardRoot,[switch]$SourceOnly)
if(-not $DashboardRoot){$DashboardRoot=Split-Path -Parent $PSScriptRoot}
$ErrorActionPreference='Stop'
$source=Join-Path $DashboardRoot 'web'
$html=[IO.File]::ReadAllText((Join-Path $source 'dashboard.html'))
$css=[IO.File]::ReadAllText((Join-Path $source 'dashboard.css'))
$js=[IO.File]::ReadAllText((Join-Path $source 'dashboard.js'))
$content=$html+$css+$js
$markers=@('dashboard-ui-contract-v1','Token 构成占比','模型 Token 占比','推理强度 Token 占比','Reasoning 为 Output 子集',
  'dashboard-skill-contract-v1','Skill 说明读取','可观测代理指标','不代表实际调用或任务成功','涉及任务（会话）','Asia/Shanghai',
  'data-page="skill"','id="skillRows"','id="usageFilters"','skill-count::before')
$markers+=@('dashboard-skill-explorer-v2','id="skillFilters"','id="skillCards"','id="skillTrend"','id="skillSources"',
  'id="skillExport"','导出审计快照','不是完整安装清单','跨 Skill 去重','skillAuditSnapshot')
$markers+=@('id="skillYAxis"','id="skillTrendReadout"','id="skillInspectDate"','id="skillMetadataNote"',
  'skill-bar-value','展开完整简介','不是历史版本','metadataAsOf')
$markers+=@('id="usagePreset"','id="usageRangeError"','全部模型','全部推理强度','currentDescriptionZh','展开中英对照','中文释义')
$markers+=@('id="skillScope"','id="skillCategory"','id="skillComposer"','id="skillPromptPreview"','id="skillCopyPrompt"',
  'inventoryAsOf','directoryState','SKILL_CATEGORIES','SKILL_WORKFLOWS','BUNDLE_KEY','known_local_skill_roots')
if(-not $html.Contains('//__SKILL_DESCRIPTIONS_ZH__')){throw 'Source UI missing the local Chinese description asset placeholder.'}
if($html.Contains('data-range=')){throw 'Date presets must have one primary select in each filter group.'}
foreach($marker in $markers){
  if(-not $content.Contains($marker)){throw "UI contract missing: $marker"}
}
$pagePath=Join-Path $DashboardRoot 'codex-usage-dashboard.html'
if((-not $SourceOnly) -and (Test-Path -LiteralPath $pagePath)){
  $page=[IO.File]::ReadAllText($pagePath)
  foreach($marker in $markers){
    if(-not $page.Contains($marker)){throw "Generated UI contract missing: $marker"}
  }
}
if($SourceOnly){Write-Output 'PASS: dashboard source UI markers. Generated output was not checked.'}
else{Write-Output 'PASS: dashboard source and generated UI markers (when generated output exists).'}
