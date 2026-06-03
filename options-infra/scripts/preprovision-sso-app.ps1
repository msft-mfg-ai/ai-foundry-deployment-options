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

$identifierUri = "api://$appId"
$currentUris = az ad app show --id $appId --query "identifierUris" -o tsv
if ($currentUris -notmatch [Regex]::Escape($identifierUri)) {
  az ad app update --id $appId --identifier-uris $identifierUri
} else {
  Write-Host "    identifierUri already set"
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
  $tmp = New-TemporaryFile
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
  Remove-Item $tmp
  Write-Host "    exposed access_as_user scope + preauthorized Teams clients"
} else {
  Write-Host "    oauth2PermissionScopes already configured"
}

# Required delegated permission against Azure AI Foundry (best-effort).
$aiResourceAppId = az ad sp list --filter "servicePrincipalNames/any(s:s eq 'https://ai.azure.com')" --query "[0].appId" -o tsv
if ($aiResourceAppId) {
  $aiScopeId = az ad sp show --id $aiResourceAppId --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv
  if ($aiScopeId) {
    Write-Host "    adding requiredResourceAccess for Azure AI Foundry user_impersonation..."
    az ad app permission add --id $appId `
      --api $aiResourceAppId `
      --api-permissions "$aiScopeId=Scope" 2>$null | Out-Null
    Write-Host "    (run 'az ad app permission admin-consent --id $appId' as a tenant admin to grant consent)"
  } else {
    Write-Warning "Could not find 'user_impersonation' scope on Foundry SP — add it manually"
  }
} else {
  Write-Warning "Azure AI Foundry SP (https://ai.azure.com) not found in this tenant — grant consent manually"
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
