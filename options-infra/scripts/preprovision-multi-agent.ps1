# preprovision-multi-agent.ps1
# ---------------------------------------------------------------------------
# Windows equivalent of preprovision-multi-agent.sh. See that script for the
# contract, idempotency rules, and phase semantics.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

if (-not $env:AZURE_ENV_NAME) {
  Write-Error 'AZURE_ENV_NAME is not set; aborting.'
}

$agentNamesRaw = $env:AGENT_NAMES
if ([string]::IsNullOrWhiteSpace($agentNamesRaw)) {
  Write-Host "-> AGENT_NAMES is empty -- Phase A deploy (Foundry only). Skipping AAD setup."
  azd env set AGENT_APP_REGS_JSON '{}'
  azd env set AGENT_APP_SECRETS_JSON '{}'
  return
}

# Strip JSON syntax chars, then comma-split (accepts "joe,bob" or '["joe","bob"]').
$agentNames = ($agentNamesRaw -replace '[\[\]"]', '') -split ',' |
  ForEach-Object { $_.Trim() } | Where-Object { $_ }
if (-not $agentNames) {
  Write-Error 'AGENT_NAMES did not contain any non-empty names; aborting.'
}

# Bot Framework token endpoint reply URL — required on EVERY app reg used as
# an ABS OAuth-connection clientId, else the connection fails with AADSTS500113.
$bfRedirect = 'https://token.botframework.com/.auth/web/redirect'

# Resolve Graph + AI Foundry scope ids ONCE — reused across all regs.
$graphResourceAppId   = '00000003-0000-0000-c000-000000000000'
$graphUserReadScopeId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
$aiResourceAppId = az ad sp list --filter "servicePrincipalNames/any(s:s eq 'https://ai.azure.com')" --query "[0].appId" -o tsv
$aiScopeId = ''
if ($aiResourceAppId) {
  $aiScopeId = az ad sp show --id $aiResourceAppId --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv
  if (-not $aiScopeId) {
    Write-Warning "Could not find 'user_impersonation' scope on Foundry SP -- add it manually"
  }
} else {
  Write-Warning "Azure AI Foundry SP (https://ai.azure.com) not found in this tenant -- grant consent manually"
}

# Teams + M365 + Outlook + Edge first-party clients allowed to call access_as_user.
$preauthClientIds = @(
  '1fec8e78-bce4-4aaf-ab1b-5451cc387264'  # Teams mobile / desktop
  '5e3ce6c0-2b1f-4285-8d4b-75ee78787346'  # Teams web
  '4765445b-32c6-49b0-83e6-1d93765276ca'  # M365 web
  '0ec893e0-5785-4de6-99da-4ed124e5296c'  # M365 desktop
  'd3590ed6-52b3-4102-aeff-aad2292ab01c'  # M365 mobile / Outlook desktop
  'bc59ab01-8403-45c6-8796-ac3ef710b3e3'  # Outlook web
  '27922004-5251-4030-b22d-91ecd9a37ea4'  # Outlook mobile
  'c0ab8ce9-e9a0-42e7-b064-33d422df41f1'  # Edge
)

# ---------------------------------------------------------------------------
# Helper: Ensure-AppSso — configures an AAD app reg as a Teams SSO target.
# Used for both per-agent regs (identifierUri = api://botid-<id>) and the
# backend reg (api://<id>, /admin OBO target).
# ---------------------------------------------------------------------------
function Ensure-AppSso {
  param(
    [string]$AppId,
    [string]$ObjId,
    [string]$IdentifierUri,
    [string]$ScopePurpose
  )

  # 1. tokenVersion=2 + signInAudience
  az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$ObjId" `
    --headers "Content-Type=application/json" `
    --body '{"api":{"requestedAccessTokenVersion":2},"signInAudience":"AzureADMyOrg"}' | Out-Null

  # 2. identifierUri
  $currentUris = (az ad app show --id $AppId --query "identifierUris" -o tsv) -split "`n" | Where-Object { $_ }
  if ($currentUris -notcontains $IdentifierUri) {
    $merged = @($currentUris) + $IdentifierUri
    az ad app update --id $AppId --identifier-uris @merged | Out-Null
    Write-Host "    added identifierUri $IdentifierUri"
  } else {
    Write-Host "    identifierUri $IdentifierUri already set"
  }

  # 3. Bot Framework reply URL
  $currentReplies = (az ad app show --id $AppId --query "web.redirectUris" -o tsv) -split "`n" | Where-Object { $_ }
  if ($currentReplies -notcontains $bfRedirect) {
    $merged = @($currentReplies) + $bfRedirect
    az ad app update --id $AppId --web-redirect-uris @merged | Out-Null
    Write-Host "    registered Bot Framework reply URL"
  } else {
    Write-Host "    Bot Framework reply URL already registered"
  }

  # 4. access_as_user scope + preauths (only if scope missing). Two PATCHes
  #    -- Graph rejects preauths in the same request as the scope they
  #    reference (scope id not yet committed).
  $existingScopes = az ad app show --id $AppId --query "api.oauth2PermissionScopes[].value" -o tsv
  if (-not $existingScopes) {
    $scopeId = [guid]::NewGuid().ToString()
    $scopeBody = @{
      api = @{
        oauth2PermissionScopes = @(
          @{
            id                      = $scopeId
            adminConsentDescription = "Allow $ScopePurpose to access Azure AI Foundry on behalf of the signed-in user."
            adminConsentDisplayName = 'Access Azure AI Foundry as the user'
            userConsentDescription  = "Allow $ScopePurpose to access Azure AI Foundry on your behalf."
            userConsentDisplayName  = 'Access Azure AI Foundry as you'
            value                   = 'access_as_user'
            type                    = 'User'
            isEnabled               = $true
          }
        )
      }
    } | ConvertTo-Json -Depth 10
    $preauthObjects = $preauthClientIds | ForEach-Object {
      [pscustomobject]@{ appId = $_; delegatedPermissionIds = @($scopeId) }
    }
    $preauthBody = @{
      api = @{
        preAuthorizedApplications = @($preauthObjects)
      }
    } | ConvertTo-Json -Depth 10

    $scopeFile   = Join-Path $PSScriptRoot ".preprovision-multi-agent-scope-$PID-$AppId.json"
    $preauthFile = Join-Path $PSScriptRoot ".preprovision-multi-agent-preauth-$PID-$AppId.json"
    try {
      Set-Content -Path $scopeFile -Value $scopeBody -Encoding utf8
      az rest --method PATCH `
        --url "https://graph.microsoft.com/v1.0/applications(appId='$AppId')" `
        --headers "Content-Type=application/json" `
        --body "@$scopeFile" | Out-Null

      Set-Content -Path $preauthFile -Value $preauthBody -Encoding utf8
      az rest --method PATCH `
        --url "https://graph.microsoft.com/v1.0/applications(appId='$AppId')" `
        --headers "Content-Type=application/json" `
        --body "@$preauthFile" | Out-Null
      Write-Host "    exposed access_as_user scope + preauthorized Teams/M365/Outlook clients"
    } finally {
      Remove-Item -Path $scopeFile   -Force -ErrorAction SilentlyContinue
      Remove-Item -Path $preauthFile -Force -ErrorAction SilentlyContinue
    }
  } else {
    Write-Host "    oauth2PermissionScopes already configured"
  }

  # 4b. web.implicitGrantSettings — enable both id_token + access_token
  #     issuance. Required for Teams silent SSO (msteams: getAuthToken)
  #     to succeed against this bot identity. Without these flags the
  #     channel sends signin/failure with {"code":"invokeerror"} and
  #     the user-OBO chain never starts. Idempotent — only PATCH if
  #     either flag is currently false.
  $idTok = az ad app show --id $AppId --query "web.implicitGrantSettings.enableIdTokenIssuance"     -o tsv
  $atTok = az ad app show --id $AppId --query "web.implicitGrantSettings.enableAccessTokenIssuance" -o tsv
  if ($idTok -ne 'True' -or $atTok -ne 'True') {
    $implicitFile = "$tmpPrefix-implicit-$AppId.json"
    '{"web":{"implicitGrantSettings":{"enableIdTokenIssuance":true,"enableAccessTokenIssuance":true}}}' | Out-File -FilePath $implicitFile -Encoding ascii
    try {
      az rest --method PATCH `
        --url "https://graph.microsoft.com/v1.0/applications(appId='$AppId')" `
        --headers "Content-Type=application/json" `
        --body "@$implicitFile" | Out-Null
      Write-Host "    enabled implicit grant (id_token + access_token issuance)"
    } finally {
      Remove-Item -Path $implicitFile -Force -ErrorAction SilentlyContinue
    }
  } else {
    Write-Host "    implicit grant already enabled"
  }

  # 5. requiredResourceAccess + idtyp optional claim
  $appState = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/applications/$ObjId`?`$select=optionalClaims,requiredResourceAccess" `
    -o json | ConvertFrom-Json
  $patch = @{}
  $changed = $false

  $optionalClaims = $appState.optionalClaims
  if (-not $optionalClaims) { $optionalClaims = [pscustomobject]@{} }
  $accessTokenClaims = @($optionalClaims.accessToken)
  if (-not ($accessTokenClaims | Where-Object { $_.name -eq 'idtyp' })) {
    $accessTokenClaims += [pscustomobject]@{
      name                 = 'idtyp'
      source               = $null
      essential            = $false
      additionalProperties = @()
    }
    if ($optionalClaims.PSObject.Properties.Name -contains 'accessToken') {
      $optionalClaims.accessToken = $accessTokenClaims
    } else {
      $optionalClaims | Add-Member -NotePropertyName accessToken -NotePropertyValue $accessTokenClaims
    }
    $patch['optionalClaims'] = $optionalClaims
    $changed = $true
  }

  $requiredResourceAccess = @($appState.requiredResourceAccess)
  function _EnsureScope($resourceAppId, $scopeId) {
    if ([string]::IsNullOrWhiteSpace($resourceAppId) -or [string]::IsNullOrWhiteSpace($scopeId)) { return }
    $entry = $script:requiredResourceAccess | Where-Object { $_.resourceAppId -eq $resourceAppId } | Select-Object -First 1
    if (-not $entry) {
      $script:requiredResourceAccess += [pscustomobject]@{
        resourceAppId  = $resourceAppId
        resourceAccess = @([pscustomobject]@{ id = $scopeId; type = 'Scope' })
      }
      $script:changed = $true
      return
    }
    $access = @($entry.resourceAccess)
    if (-not ($access | Where-Object { $_.id -eq $scopeId -and $_.type -eq 'Scope' })) {
      $access += [pscustomobject]@{ id = $scopeId; type = 'Scope' }
      $entry.resourceAccess = $access
      $script:changed = $true
    }
  }
  $script:requiredResourceAccess = $requiredResourceAccess
  $script:changed = $changed
  _EnsureScope $graphResourceAppId $graphUserReadScopeId
  _EnsureScope $aiResourceAppId    $aiScopeId
  if ($script:changed) { $patch['requiredResourceAccess'] = $script:requiredResourceAccess }

  if ($patch.Count -gt 0) {
    $patchFile = Join-Path $PSScriptRoot ".preprovision-multi-agent-patch-$PID-$AppId.json"
    try {
      $patch | ConvertTo-Json -Depth 20 | Set-Content -Path $patchFile -Encoding utf8
      az rest --method PATCH `
        --uri "https://graph.microsoft.com/v1.0/applications/$ObjId" `
        --headers "Content-Type=application/json" `
        --body "@$patchFile" | Out-Null
      Write-Host "    patched optionalClaims.accessToken[idtyp] and requiredResourceAccess"
    } finally {
      Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
  } else {
    Write-Host "    optional claims and API permissions already configured"
  }

  az ad app permission admin-consent --id $AppId 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Write-Host "    admin consent granted"
  } else {
    Write-Warning "Admin consent was not granted; run 'az ad app permission admin-consent --id $AppId' as a tenant admin"
  }
}

# ---------------------------------------------------------------------------
# 1. Per-agent app registrations -- bot identity + Teams SSO target
# ---------------------------------------------------------------------------
Write-Host "-> Ensuring per-agent AAD app registrations..."

$agentMap    = [ordered]@{}
$agentSecrets = [ordered]@{}
foreach ($agent in $agentNames) {
  $displayName = "agent-$agent-$($env:AZURE_ENV_NAME)"
  $appId = az ad app list --display-name $displayName --query "[0].appId" -o tsv
  if (-not $appId) {
    $appId = az ad app create `
      --display-name $displayName `
      --sign-in-audience AzureADMyOrg `
      --query appId -o tsv
    Write-Host "    created $displayName -> appId=$appId"
  } else {
    Write-Host "    found existing $displayName -> appId=$appId"
  }

  az ad sp show --id $appId 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { az ad sp create --id $appId | Out-Null }

  $objId = az ad app show --id $appId --query id -o tsv

  Write-Host "  -> Configuring SSO for $agent..."
  Ensure-AppSso -AppId $appId -ObjId $objId -IdentifierUri "api://botid-$appId" -ScopePurpose "the Teams bot $agent"

  Write-Host "  -> Minting client secret for $agent..."
  $secret = az ad app credential reset `
    --id $appId `
    --append `
    --display-name "azd-$($env:AZURE_ENV_NAME)" `
    --years 1 `
    --query password -o tsv

  $agentMap[$agent]     = $appId
  $agentSecrets[$agent] = $secret
}

$agentJson        = ($agentMap | ConvertTo-Json -Compress)
$agentSecretsJson = ($agentSecrets | ConvertTo-Json -Compress)

# ---------------------------------------------------------------------------
# 2. Shared teams-app-backend app registration -- /admin OIDC + OBO only
# ---------------------------------------------------------------------------
$backendDisplayName = "teams-app-backend-$($env:AZURE_ENV_NAME)"
Write-Host "-> Ensuring backend AAD app '$backendDisplayName' exists..."

$backendAppId = az ad app list --display-name $backendDisplayName --query "[0].appId" -o tsv
if (-not $backendAppId) {
  $backendAppId = az ad app create `
    --display-name $backendDisplayName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
  Write-Host "    created backend appId=$backendAppId"
} else {
  Write-Host "    found existing backend appId=$backendAppId"
}

az ad sp show --id $backendAppId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { az ad sp create --id $backendAppId | Out-Null }
$backendObjId = az ad app show --id $backendAppId --query id -o tsv

# Backend uses api://<appId> -- NOT a bot SSO target, no botid- needed.
Write-Host "  -> Configuring backend reg..."
Ensure-AppSso -AppId $backendAppId -ObjId $backendObjId -IdentifierUri "api://$backendAppId" -ScopePurpose 'the proxy admin endpoints'

Write-Host "-> Minting fresh backend client secret..."
$backendSecret = az ad app credential reset `
  --id $backendAppId `
  --append `
  --display-name "azd-$($env:AZURE_ENV_NAME)" `
  --years 1 `
  --query password -o tsv

# ---------------------------------------------------------------------------
# 3. Write outputs to azd env (read by main.bicepparam)
# ---------------------------------------------------------------------------
azd env set AGENT_APP_REGS_JSON    $agentJson
azd env set AGENT_APP_SECRETS_JSON $agentSecretsJson
azd env set TEAMS_APP_BACKEND_ID   $backendAppId
azd env set TEAMS_APP_BACKEND_SECRET $backendSecret

Write-Host ""
Write-Host "[OK] Preprovision complete."
Write-Host "    AGENT_APP_REGS_JSON      = $agentJson"
Write-Host "    AGENT_APP_SECRETS_JSON   = (written to azd env, $($agentSecrets.Count) secrets)"
Write-Host "    TEAMS_APP_BACKEND_ID     = $backendAppId"
Write-Host "    TEAMS_APP_BACKEND_SECRET = (written to azd env)"
