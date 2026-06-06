#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Multi-agent postprovision: creates Federated Identity Credentials on each
  agent app reg trusting the container UAMI, then prints a deploy summary.

.DESCRIPTION
  See postprovision-multi-agent.sh for design/rationale. This is the Windows
  equivalent — same env vars, same FIC parameters, same idempotency rules.

  Required azd env values (emitted by main.bicep outputs):
    AGENT_APP_REGS_JSON                 '{"agent1":"<appId>",...}'
    TEAMS_PROXY_IDENTITY_PRINCIPAL_ID    UAMI principalId (FIC subject)
    TEAMS_PROXY_IDENTITY_CLIENT_ID       UAMI client id (for summary)
    TEAMS_PROXY_IDENTITY_RESOURCE_ID     UAMI resource id (for summary)
    TEAMS_APP_BACKEND_ID                shared backend reg appId
    PROXY_FQDN                          container app FQDN
#>

$ErrorActionPreference = 'Stop'

Write-Host "=========================================="
Write-Host "Multi-agent postprovision: FIC + summary"
Write-Host "=========================================="

function Get-AzdValue([string] $key) {
    $v = & azd env get-value $key 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return $v
}

$agentAppRegsJson = Get-AzdValue 'AGENT_APP_REGS_JSON'
if ([string]::IsNullOrWhiteSpace($agentAppRegsJson)) { $agentAppRegsJson = '{}' }
$principalId = Get-AzdValue 'TEAMS_PROXY_IDENTITY_PRINCIPAL_ID'
$uamiClient  = Get-AzdValue 'TEAMS_PROXY_IDENTITY_CLIENT_ID'
$uamiRid     = Get-AzdValue 'TEAMS_PROXY_IDENTITY_RESOURCE_ID'
$backendId   = Get-AzdValue 'TEAMS_APP_BACKEND_ID'
$proxyFqdn   = Get-AzdValue 'PROXY_FQDN'
$tenant      = (& az account show --query tenantId -o tsv).Trim()

$agentMap = $agentAppRegsJson | ConvertFrom-Json -AsHashtable
if (-not $agentMap -or $agentMap.Count -eq 0) {
    Write-Host "[postprovision] AGENT_APP_REGS_JSON is empty — Phase A. Skipping FIC creation."
    return
}

if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw "TEAMS_PROXY_IDENTITY_PRINCIPAL_ID is empty — bicep didn't emit it. Aborting."
}

$issuer = "https://login.microsoftonline.com/$tenant/v2.0"
$ficName = 'container-uami-fic'

Write-Host ""
Write-Host "FIC config:"
Write-Host "  issuer   = $issuer"
Write-Host "  subject  = $principalId  (container UAMI principalId)"
Write-Host "  audience = api://AzureADTokenExchange"
Write-Host ""

foreach ($agent in $agentMap.Keys) {
    $appId = $agentMap[$agent]
    Write-Host "----- $agent (appId=$appId) -----"

    $existing = (& az ad app federated-credential list --id $appId `
        --query "[?name=='$ficName'].name" -o tsv 2>$null) | Where-Object { $_ }

    $params = @{
        name      = $ficName
        issuer    = $issuer
        subject   = $principalId
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress

    if ($existing) {
        Write-Host "  FIC '$ficName' already exists — updating subject (idempotent)..."
        & az ad app federated-credential update `
            --id $appId `
            --federated-credential-id $ficName `
            --parameters $params | Out-Null
    }
    else {
        Write-Host "  creating FIC '$ficName'..."
        & az ad app federated-credential create `
            --id $appId `
            --parameters $params | Out-Null
        Write-Host "  created."
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Deployment summary"
Write-Host "=========================================="
Write-Host "Tenant:                   $tenant"
Write-Host "Container UAMI principal: $principalId"
Write-Host "Container UAMI client:    $uamiClient"
Write-Host "Container UAMI resource:  $uamiRid"
Write-Host "Proxy FQDN:               $proxyFqdn"
Write-Host "Teams App backend appId:  $backendId"
Write-Host "Identifier URI:           api://$backendId"
Write-Host ""
Write-Host "Per-agent app regs (each has FIC trusting the container UAMI):"
foreach ($agent in $agentMap.Keys) {
    $appId = $agentMap[$agent]
    Write-Host ("  - {0,-20} appId={1}" -f $agent, $appId)
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Sideload each teams-app/build/teams-app-<agent>-<direct|proxy>.zip"
Write-Host "     into Teams (Apps -> Manage your apps -> Upload a custom app)."
Write-Host "  2. Open the chat - silent SSO should succeed; agent should respond."
Write-Host "=========================================="
