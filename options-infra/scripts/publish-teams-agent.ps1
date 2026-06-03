#!/usr/bin/env pwsh
# =============================================================================
# Shared azd postprovision hook: publish a Foundry agent to Microsoft 365
# and build a Teams app sideload package.
# (Windows / pwsh counterpart of publish-teams-agent.sh — keep behaviours
# in sync between the two.)
# =============================================================================

$ErrorActionPreference = 'Continue'

Write-Host "=========================================="
Write-Host "Publishing agent to Microsoft 365"
Write-Host "=========================================="
Write-Host "CWD: $(Get-Location)"
Write-Host ""

$envDump = (& azd env get-values 2>&1) -join "`n"
Write-Host "[publish] Available azd env keys:"
$envDump -split "`n" | ForEach-Object {
  if ($_ -match '^([A-Z_a-z0-9]+)=') { "  - $($matches[1])" }
} | Sort-Object | Write-Host
Write-Host ""

function Get-AzdValue($key) {
  foreach ($line in $envDump -split "`n") {
    if ($line -match "^$key=(.*)$") {
      return $matches[1].Trim('"')
    }
  }
  return ''
}

$sub      = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$rg       = Get-AzdValue 'FOUNDRY_RESOURCE_GROUP'
$foundry  = Get-AzdValue 'FOUNDRY_NAME'
$project  = Get-AzdValue 'PROJECT_NAME'
$location = Get-AzdValue 'LOCATION'
$agent    = Get-AzdValue 'AGENT_NAME'
$guid     = Get-AzdValue 'AGENT_GUID'
$botId    = Get-AzdValue 'AGENT_BLUEPRINT_APP_ID'

Write-Host "[publish] SUB=$sub  RG=$rg  FOUNDRY=$foundry  PROJECT=$project  LOCATION=$location"
Write-Host "[publish] AGENT=$agent  GUID=$guid  BOT_ID=$botId"

$missing = @()
foreach ($pair in @(@{n='SUB';v=$sub},@{n='RG';v=$rg},@{n='FOUNDRY';v=$foundry},@{n='PROJECT';v=$project},@{n='LOCATION';v=$location},@{n='AGENT';v=$agent},@{n='GUID';v=$guid},@{n='BOT_ID';v=$botId})) {
  if ([string]::IsNullOrWhiteSpace($pair.v)) { $missing += $pair.n }
}
if ($missing.Count -gt 0) {
  Write-Host ""
  Write-Host "[publish] ERROR: missing azd env values: $($missing -join ', ')"
  Write-Host "[publish] Verify Bicep outputs and re-run 'azd provision' to refresh azd env."
  exit 1
}

$workspace = "$foundry@$project@AML"
$url = "https://$location.api.azureml.ms/agent-asset/v2.0/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.MachineLearningServices/workspaces/$workspace/microsoft365/publish"

$body = @{
  subscriptionId         = $sub
  agentGuid              = $guid
  agentName              = $agent
  botId                  = $botId
  appPublishScope        = 'Tenant'
  publishAsDigitalWorker = $false
  appVersion             = '1.0.0'
  shortDescription       = "$agent (Foundry)"
  fullDescription        = "$agent (Foundry) — published via azd"
  developerName          = 'AI Foundry'
  developerWebsiteUrl    = 'https://learn.microsoft.com/azure/ai-foundry/'
  privacyUrl             = 'https://learn.microsoft.com/azure/ai-foundry/'
  termsOfUseUrl          = 'https://learn.microsoft.com/azure/ai-foundry/'
} | ConvertTo-Json -Depth 10 -Compress

$bodyFile = New-TemporaryFile
Set-Content -Path $bodyFile -Value $body -Encoding utf8 -NoNewline
Write-Host ""
Write-Host "POST $url"
$out = az rest --method post --url $url --resource 'https://ai.azure.com' `
               --headers 'Content-Type=application/json' --body "@$bodyFile" 2>&1
if ($LASTEXITCODE -ne 0) {
  if ($out -match 'version already exists') {
    Write-Host "Agent already published — continuing."
  } else {
    Write-Host "Publish failed:`n$out"
    exit 1
  }
} else {
  Write-Host "Publish response:`n$out"
}
Remove-Item $bodyFile -Force

Write-Host ""
Write-Host "=========================================="
Write-Host "Building Teams app package"
Write-Host "=========================================="

$manifest = (& azd env get-value TEAMS_MANIFEST_JSON 2>&1) -join "`n"
if ([string]::IsNullOrWhiteSpace($manifest)) {
  Write-Host "TEAMS_MANIFEST_JSON not found."
  exit 1
}

$buildDir = "teams-app/build"
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$manifest | Out-File -FilePath "$buildDir/manifest.json" -Encoding utf8 -NoNewline
Copy-Item -Force "teams-app/default-color-icon.png"   $buildDir
Copy-Item -Force "teams-app/default-outline-icon.png" $buildDir

$zipPath = "$buildDir/teams-app.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$buildDir/manifest.json","$buildDir/default-color-icon.png","$buildDir/default-outline-icon.png" `
                 -DestinationPath $zipPath

Write-Host ""
Write-Host "Teams app package: $((Resolve-Path $zipPath).Path)"
Write-Host "Sideload via Teams → Apps → Manage your apps → Upload a custom app."

# Optional second package: proxy bot manifest (foundry-byo-vnet-teams).
# Only emitted when main.bicep exposes TEAMS_MANIFEST_PROXY_JSON.
# Use `azd env get-value` (singular) for the raw unescaped JSON — the
# multi-value `get-values` output escapes embedded quotes (\") which would
# corrupt the manifest.
$manifestProxy = (& azd env get-value TEAMS_MANIFEST_PROXY_JSON 2>$null) -join "`n"
if (-not [string]::IsNullOrWhiteSpace($manifestProxy)) {
  Write-Host ""
  Write-Host "=========================================="
  Write-Host "Building Teams app package (proxy bot)"
  Write-Host "=========================================="
  $manifestProxy | Out-File -FilePath "$buildDir/manifest.json" -Encoding utf8 -NoNewline
  $proxyZip = "$buildDir/teams-app-proxy.zip"
  if (Test-Path $proxyZip) { Remove-Item $proxyZip -Force }
  Compress-Archive -Path "$buildDir/manifest.json","$buildDir/default-color-icon.png","$buildDir/default-outline-icon.png" `
                   -DestinationPath $proxyZip
  Write-Host "Proxy Teams app package: $((Resolve-Path $proxyZip).Path)"
}
Write-Host "=========================================="
