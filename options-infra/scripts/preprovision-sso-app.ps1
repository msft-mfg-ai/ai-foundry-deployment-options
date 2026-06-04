# preprovision-sso-app.ps1
# ---------------------------------------------------------------------------
# Windows equivalent of preprovision-sso-app.sh. See that script for the
# contract, idempotency rules, and the manual admin-consent step.
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

if (-not $env:AZURE_ENV_NAME) {
  Write-Error 'AZURE_ENV_NAME is not set; aborting.'
}

$displayName = "sso-foundry-teams-$($env:AZURE_ENV_NAME)"
Write-Host "→ Ensuring SSO AAD app '$displayName' exists..."

$appId = az ad app list --display-name $displayName --query "[0].appId" -o tsv
if (-not $appId) {
  $appId = az ad app create `
    --display-name $displayName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
  Write-Host "    created appId=$appId"
} else {
  Write-Host "    found existing appId=$appId"
}

# Ensure SP exists for the app.
az ad sp show --id $appId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { az ad sp create --id $appId | Out-Null }

# Set requestedAccessTokenVersion=2 — required by tenant policy when the
# identifierUri uses the api://botid-<botId> format that Teams Bot SSO needs.
# Also enforce signInAudience=AzureADMyOrg here (idempotent on reused apps —
# `az ad app create --sign-in-audience` only applies on first creation, so a
# reused app from an earlier multi-tenant run would otherwise drift).
Write-Host "-> Enforcing requestedAccessTokenVersion=2 and signInAudience=AzureADMyOrg..."
$objId = az ad app show --id $appId --query id -o tsv
az rest --method PATCH `
  --uri "https://graph.microsoft.com/v1.0/applications/$objId" `
  --headers "Content-Type=application/json" `
  --body '{"api":{"requestedAccessTokenVersion":2},"signInAudience":"AzureADMyOrg"}' | Out-Null

# Teams Bot SSO requires identifierUri = api://botid-<aad-app-id>.
# In the Teams docs, {YourBotId} is the Microsoft Entra application ID that
# owns the SSO scope, i.e. this preprovision-created SSO app's appId.
$identifierUri = "api://botid-$appId"
$currentUris = (az ad app show --id $appId --query "identifierUris" -o tsv) -split "`n" | Where-Object { $_ }
if ($currentUris -notcontains $identifierUri) {
  $merged = @($currentUris) + $identifierUri
  az ad app update --id $appId --identifier-uris @merged
  Write-Host "    added identifierUri $identifierUri"
} else {
  Write-Host "    identifierUri $identifierUri already set"
}

# Register the Bot Framework token endpoint as a web reply URL. Without this
# the OAuth Connection Setting test returns AADSTS500113 because AAD has
# nowhere to send the auth code back to.
$bfRedirect = 'https://token.botframework.com/.auth/web/redirect'
$currentReplies = (az ad app show --id $appId --query "web.redirectUris" -o tsv) -split "`n" | Where-Object { $_ }
if ($currentReplies -notcontains $bfRedirect) {
  $merged = @($currentReplies) + $bfRedirect
  az ad app update --id $appId --web-redirect-uris @merged
  Write-Host "    registered Bot Framework reply URL"
} else {
  Write-Host "    Bot Framework reply URL already registered"
}

# Patch oauth2PermissionScopes + preAuthorizedApplications only if no scope
# is exposed yet (so re-runs don't clobber operator edits).
$existingScopes = az ad app show --id $appId --query "api.oauth2PermissionScopes[].value" -o tsv
if (-not $existingScopes) {
  $scopeId = [guid]::NewGuid().ToString()
  # Graph rejects preAuthorizedApplications referencing a scope id that
  # doesn't exist yet — even in the same PATCH body — so we split into two
  # requests: register the scope first, then add the preauthorized clients.
  $scopeBody = @{
    api = @{
      oauth2PermissionScopes = @(
        @{
          id = $scopeId
          adminConsentDescription = 'Allow the app to access Azure AI Foundry on behalf of the signed-in user.'
          adminConsentDisplayName = 'Access Azure AI Foundry as the user'
          userConsentDescription  = 'Allow the app to access Azure AI Foundry on your behalf.'
          userConsentDisplayName  = 'Access Azure AI Foundry as you'
          value = 'access_as_user'
          type  = 'User'
          isEnabled = $true
        }
      )
    }
  } | ConvertTo-Json -Depth 10
  $tmp = Join-Path $PSScriptRoot ".preprovision-sso-app-scope-$PID.json"
  Set-Content -Path $tmp -Value $scopeBody -Encoding utf8
  az rest --method PATCH `
    --url "https://graph.microsoft.com/v1.0/applications(appId='$appId')" `
    --headers "Content-Type=application/json" `
    --body "@$tmp"

  $preauthBody = @{
    api = @{
      preAuthorizedApplications = @(
        @{ appId = '1fec8e78-bce4-4aaf-ab1b-5451cc387264'; delegatedPermissionIds = @($scopeId) }
        @{ appId = '5e3ce6c0-2b1f-4285-8d4b-75ee78787346'; delegatedPermissionIds = @($scopeId) }
      )
    }
  } | ConvertTo-Json -Depth 10
  Set-Content -Path $tmp -Value $preauthBody -Encoding utf8
  az rest --method PATCH `
    --url "https://graph.microsoft.com/v1.0/applications(appId='$appId')" `
    --headers "Content-Type=application/json" `
    --body "@$tmp"
  Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
  Write-Host "    exposed access_as_user scope + preauthorized Teams clients"
} else {
  Write-Host "    oauth2PermissionScopes already configured"
}

# Required delegated permissions + Teams SSO token typing. Preserve existing
# permissions/claims and only patch when something is missing.
Write-Host "→ Ensuring optional claims and delegated API permissions are configured..."
$graphResourceAppId = '00000003-0000-0000-c000-000000000000'
$graphUserReadScopeId = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'
$aiResourceAppId = az ad sp list --filter "servicePrincipalNames/any(s:s eq 'https://ai.azure.com')" --query "[0].appId" -o tsv
$aiScopeId = ''
if ($aiResourceAppId) {
  $aiScopeId = az ad sp show --id $aiResourceAppId --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv
  if (-not $aiScopeId) {
    Write-Warning "Could not find 'user_impersonation' scope on Foundry SP — add it manually"
  }
} else {
  Write-Warning "Azure AI Foundry SP (https://ai.azure.com) not found in this tenant — grant consent manually"
}

$appState = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/applications/$objId`?`$select=optionalClaims,requiredResourceAccess" `
  -o json | ConvertFrom-Json
$patch = @{}
$changed = $false

$optionalClaims = $appState.optionalClaims
if (-not $optionalClaims) { $optionalClaims = [pscustomobject]@{} }
$accessTokenClaims = @($optionalClaims.accessToken)
if (-not ($accessTokenClaims | Where-Object { $_.name -eq 'idtyp' })) {
  $accessTokenClaims += [pscustomobject]@{
    name = 'idtyp'
    source = $null
    essential = $false
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
function Ensure-ScopePermission($resourceAppId, $scopeId) {
  if ([string]::IsNullOrWhiteSpace($resourceAppId) -or [string]::IsNullOrWhiteSpace($scopeId)) { return }
  $entry = $script:requiredResourceAccess | Where-Object { $_.resourceAppId -eq $resourceAppId } | Select-Object -First 1
  if (-not $entry) {
    $script:requiredResourceAccess += [pscustomobject]@{
      resourceAppId = $resourceAppId
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
Ensure-ScopePermission $graphResourceAppId $graphUserReadScopeId
Ensure-ScopePermission $aiResourceAppId $aiScopeId
if ($changed) { $patch['requiredResourceAccess'] = $requiredResourceAccess }

if ($patch.Count -gt 0) {
  $patchFile = Join-Path $PSScriptRoot ".preprovision-sso-app-patch-$PID.json"
  try {
    $patch | ConvertTo-Json -Depth 20 | Set-Content -Path $patchFile -Encoding utf8
    az rest --method PATCH `
      --uri "https://graph.microsoft.com/v1.0/applications/$objId" `
      --headers "Content-Type=application/json" `
      --body "@$patchFile" | Out-Null
    Write-Host "    patched optionalClaims.accessToken[idtyp] and requiredResourceAccess"
  } finally {
    Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
  }
} else {
  Write-Host "    optional claims and API permissions already configured"
}

az ad app permission admin-consent --id $appId 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  Write-Host "    admin consent granted for configured API permissions"
} else {
  Write-Warning "Admin consent was not granted; run 'az ad app permission admin-consent --id $appId' as a tenant admin"
}

Write-Host "→ Minting fresh client secret..."
$clientSecret = az ad app credential reset `
  --id $appId `
  --append `
  --display-name "azd-$($env:AZURE_ENV_NAME)" `
  --years 1 `
  --query password -o tsv

azd env set SSO_APP_ID $appId
azd env set SSO_APP_SECRET $clientSecret
Write-Host "✓ SSO_APP_ID and SSO_APP_SECRET written to azd env"
