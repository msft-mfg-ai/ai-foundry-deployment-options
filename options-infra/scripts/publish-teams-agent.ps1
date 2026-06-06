#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Multi-agent Teams publish: POSTs /microsoft365/publish per agent and writes
  N x 2 Teams sideload zips into ./teams-app/build/.

.DESCRIPTION
  Windows mirror of publish-teams-agent.sh. Reads the multi-agent contract
  emitted by main.bicep:
    AGENT_PUBLISH_INFO    JSON array of {agentName, agentGuid, blueprintAppId}
    TEAMS_MANIFESTS       JSON array of {agentName, direct, proxy}
    FOUNDRY_NAME, FOUNDRY_RESOURCE_GROUP, PROJECT_NAME, LOCATION
    AZURE_SUBSCRIPTION_ID

  Per agent:
    1. POST /microsoft365/publish (idempotent — "version already exists" OK).
    2. Write 2 zips: teams-app-<agent>-<direct|proxy>.zip
#>

$ErrorActionPreference = 'Stop'

Write-Host "=========================================="
Write-Host "Multi-agent Teams publish"
Write-Host "=========================================="

function Get-AzdValue([string] $key) {
    $v = & azd env get-value $key 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

$sub      = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$rg       = Get-AzdValue 'FOUNDRY_RESOURCE_GROUP'
$foundry  = Get-AzdValue 'FOUNDRY_NAME'
$project  = Get-AzdValue 'PROJECT_NAME'
$location = Get-AzdValue 'LOCATION'

# Singular get-value preserves embedded JSON quoting (multi-value get-values
# shell-escapes them which corrupts the manifest).
$publishInfoJson = Get-AzdValue 'AGENT_PUBLISH_INFO'
$manifestsJson   = Get-AzdValue 'TEAMS_MANIFESTS'

if ([string]::IsNullOrWhiteSpace($publishInfoJson) -or $publishInfoJson -eq '[]') {
    Write-Host "[publish] AGENT_PUBLISH_INFO is empty — Phase A (no agents to publish). Skipping."
    return
}
if ([string]::IsNullOrWhiteSpace($manifestsJson) -or $manifestsJson -eq '[]') {
    Write-Host "[publish] TEAMS_MANIFESTS is empty — nothing to package. Skipping."
    return
}

$missing = @()
foreach ($v in @{Sub=$sub; Rg=$rg; Foundry=$foundry; Project=$project; Location=$location}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($v.Value)) { $missing += $v.Key }
}
if ($missing.Count -gt 0) {
    throw "Missing azd env values: $($missing -join ', ')"
}

$workspace      = "$foundry@$project@AML"
$publishUrlBase = "https://$location.api.azureml.ms/agent-asset/v2.0/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.MachineLearningServices/workspaces/$workspace/microsoft365/publish"

$buildDir = 'teams-app/build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$entries   = $publishInfoJson | ConvertFrom-Json
$manifests = $manifestsJson   | ConvertFrom-Json

Write-Host ""
Write-Host "Agents to publish:"
foreach ($e in $entries) {
    Write-Host "  - $($e.agentName) (guid=$($e.agentGuid), botId=$($e.blueprintAppId))"
}
Write-Host ""

$publishFailed = $false

foreach ($e in $entries) {
    $agent  = $e.agentName
    $guid   = $e.agentGuid
    $botId  = $e.blueprintAppId
    Write-Host "----- $agent -----"

    if ([string]::IsNullOrWhiteSpace($guid) -or [string]::IsNullOrWhiteSpace($botId)) {
        Write-Host "  [publish] WARN: missing guid or blueprintAppId for $agent — skipping M365 publish."
    }
    else {
        $body = @{
            subscriptionId         = $sub
            agentGuid              = $guid
            agentName              = $agent
            botId                  = $botId
            appPublishScope        = 'Tenant'
            publishAsDigitalWorker = $false
            appVersion             = '1.0.0'
            shortDescription       = "$agent (Foundry)"
            fullDescription        = "$agent (Foundry) - published via azd"
            developerName          = 'AI Foundry'
            developerWebsiteUrl    = 'https://learn.microsoft.com/azure/ai-foundry/'
            privacyUrl             = 'https://learn.microsoft.com/azure/ai-foundry/'
            termsOfUseUrl          = 'https://learn.microsoft.com/azure/ai-foundry/'
        } | ConvertTo-Json -Compress

        $bodyFile = New-TemporaryFile
        Set-Content -Path $bodyFile -Value $body -NoNewline -Encoding UTF8

        $publishOut = & az rest --method post --url $publishUrlBase `
            --resource 'https://ai.azure.com' `
            --headers 'Content-Type=application/json' `
            --body "@$($bodyFile.FullName)" 2>&1
        $publishRc = $LASTEXITCODE

        if ($publishRc -eq 0) {
            Write-Host "  [publish] M365 publish OK"
        }
        elseif ($publishOut -match 'version already exists') {
            Write-Host "  [publish] already published (version exists)"
        }
        else {
            Write-Host "  [publish] FAILED rc=${publishRc}:"
            $publishOut | ForEach-Object { Write-Host "    $_" }
            $publishFailed = $true
        }
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }

    $match = $manifests | Where-Object { $_.agentName -eq $agent } | Select-Object -First 1
    if (-not $match) {
        Write-Host "  [publish] WARN: no manifest for $agent"
        continue
    }

    foreach ($kind in @('direct', 'proxy')) {
        $manifestObj = $match.$kind
        if (-not $manifestObj) { continue }

        $manifestFile = Join-Path $buildDir "manifest-$agent-$kind.json"
        $zipFile      = Join-Path $buildDir "teams-app-$agent-$kind.zip"
        $manifestObj | ConvertTo-Json -Depth 32 | Set-Content -Path $manifestFile -Encoding UTF8
        Write-Host "  wrote $manifestFile"

        # Stage manifest + icons under a fixed name and zip them.
        Copy-Item $manifestFile (Join-Path $buildDir 'manifest.json') -Force
        if (Test-Path 'teams-app/default-color-icon.png')   { Copy-Item 'teams-app/default-color-icon.png'   (Join-Path $buildDir 'default-color-icon.png')   -Force }
        if (Test-Path 'teams-app/default-outline-icon.png') { Copy-Item 'teams-app/default-outline-icon.png' (Join-Path $buildDir 'default-outline-icon.png') -Force }
        if (Test-Path $zipFile) { Remove-Item $zipFile -Force }

        $files = @('manifest.json', 'default-color-icon.png', 'default-outline-icon.png') |
                 ForEach-Object { Join-Path $buildDir $_ } |
                 Where-Object { Test-Path $_ }
        Compress-Archive -Path $files -DestinationPath $zipFile -Force
        Write-Host "  built $zipFile"
    }
    Remove-Item (Join-Path $buildDir 'manifest.json') -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Generated Teams app zips:"
Get-ChildItem -Path $buildDir -Filter 'teams-app-*.zip' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.FullName)" }
Write-Host ""
Write-Host "Sideload each zip via Teams -> Apps -> Manage your apps -> Upload a custom app."
Write-Host "=========================================="

if ($publishFailed) { exit 1 }
exit 0
