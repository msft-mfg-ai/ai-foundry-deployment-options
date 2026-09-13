$ErrorActionPreference = 'Stop'

function Get-AzdValue([string]$Name) {
  $current = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
  $value = azd env get-value $Name 2>$null
  if ($LASTEXITCODE -eq 0) { return [string]$value }
  return ''
}

$gatewayUrl = Get-AzdValue 'AGENTGATEWAY_URL'
$gatewayFqdn = Get-AzdValue 'AGENTGATEWAY_FQDN'
$uiAppId = Get-AzdValue 'AGENTGATEWAY_UI_CLIENT_ID'
$apiAppId = Get-AzdValue 'AGENTGATEWAY_API_CLIENT_ID'

if ([string]::IsNullOrWhiteSpace($gatewayUrl) -and -not [string]::IsNullOrWhiteSpace($gatewayFqdn)) {
  $gatewayUrl = "https://$gatewayFqdn"
}
if ([string]::IsNullOrWhiteSpace($gatewayUrl) -or
    [string]::IsNullOrWhiteSpace($uiAppId) -or
    [string]::IsNullOrWhiteSpace($apiAppId)) {
  throw 'AGENTGATEWAY_URL/FQDN and Entra application IDs must be available in the azd environment.'
}

if ($gatewayUrl -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
  $gatewayUrl = "https://$gatewayUrl"
}
$gatewayUri = [uri]$gatewayUrl
if ($gatewayUri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($gatewayUri.Host)) {
  throw 'The agentgateway URL must be a valid HTTPS URL.'
}
$callback = "https://$($gatewayUri.Host)/oauth/callback"

$redirects = @((az ad app show --id $uiAppId --query 'web.redirectUris' -o json | ConvertFrom-Json))
if ($redirects -notcontains $callback) {
  $redirects += $callback
  az ad app update --id $uiAppId --web-redirect-uris @redirects | Out-Null
  Write-Host '→ Added the final UI callback without removing existing redirects.'
} else {
  Write-Host '→ UI callback is already registered.'
}

$apiApp = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/applications(appId='$apiAppId')`?`$select=api,appRoles,signInAudience" `
  -o json | ConvertFrom-Json

$scopeValues = @($apiApp.api.oauth2PermissionScopes |
  Where-Object { $_.isEnabled } |
  ForEach-Object { $_.value })
foreach ($requiredScope in @('gateway_access', 'mcp_access')) {
  if ($scopeValues -notcontains $requiredScope) {
    throw "Missing enabled delegated scope '$requiredScope'."
  }
}
if ($apiApp.api.requestedAccessTokenVersion -ne 2) {
  throw 'The resource application is not configured for v2 access tokens.'
}
if ($apiApp.signInAudience -ne 'AzureADMyOrg') {
  throw 'The resource application is not single-tenant.'
}
$appRole = $apiApp.appRoles | Where-Object {
  $_.value -eq 'gateway.invoke' -and
  $_.isEnabled -and
  $_.allowedMemberTypes -contains 'Application'
} | Select-Object -First 1
if (-not $appRole) {
  throw 'The gateway.invoke application role is missing or disabled.'
}

$verifiedRedirects = @((az ad app show --id $uiAppId --query 'web.redirectUris' -o json | ConvertFrom-Json))
if ($verifiedRedirects -notcontains $callback) {
  throw 'The final UI callback was not registered.'
}

Write-Host "✓ Verified single-tenant v2 resource app, delegated scopes, application role, and UI callback: $callback"
