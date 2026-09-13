$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
  throw 'AZURE_ENV_NAME is not set; aborting.'
}

function Get-AzdValue([string]$Name) {
  $current = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($current)) { return $current }
  $value = azd env get-value $Name 2>$null
  if ($LASTEXITCODE -eq 0) { return [string]$value }
  return ''
}

function Set-AzdValue([string]$Name, [string]$Value) {
  azd env set $Name $Value | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to set azd environment value '$Name'." }
}

function Ensure-Application([string]$DisplayName) {
  $appId = az ad app list --display-name $DisplayName --query '[0].appId' -o tsv 2>$null
  if ([string]::IsNullOrWhiteSpace($appId)) {
    $appId = az ad app create `
      --display-name $DisplayName `
      --sign-in-audience AzureADMyOrg `
      --query appId -o tsv
    Write-Host "    created application '$DisplayName'"
  } else {
    Write-Host "    reused application '$DisplayName'"
  }

  az ad sp show --id $appId 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    az ad sp create --id $appId | Out-Null
  }
  return [string]$appId
}

function Ensure-DelegatedScope(
  [System.Collections.ArrayList]$Scopes,
  [string]$Value,
  [string]$DisplayName,
  [string]$Description
) {
  $scope = $Scopes | Where-Object { $_.value -eq $Value } | Select-Object -First 1
  if (-not $scope) {
    $scope = [pscustomobject]@{
      id = [guid]::NewGuid().ToString()
      value = $Value
      type = 'User'
      isEnabled = $true
      adminConsentDisplayName = $DisplayName
      adminConsentDescription = $Description
      userConsentDisplayName = $DisplayName
      userConsentDescription = $Description
    }
    [void]$Scopes.Add($scope)
  } else {
    $scope.isEnabled = $true
    if (-not $scope.type) { $scope.type = 'User' }
  }
  return $scope
}

function Set-ObjectProperty([object]$Object, [string]$Name, [object]$Value) {
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

$apiDisplayName = "agentgateway-api-$($env:AZURE_ENV_NAME)"
$uiDisplayName = "agentgateway-ui-$($env:AZURE_ENV_NAME)"

Write-Host '→ Ensuring the agentgateway resource application...'
$apiAppId = Ensure-Application $apiDisplayName
$apiObjectId = az ad app show --id $apiAppId --query id -o tsv
$apiSpObjectId = az ad sp show --id $apiAppId --query id -o tsv
$apiAudience = "api://$apiAppId"
$apiState = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId`?`$select=api,appRoles,identifierUris,signInAudience,isFallbackPublicClient,publicClient,web" `
  -o json | ConvertFrom-Json

$scopes = [System.Collections.ArrayList]@(
  @($apiState.api.oauth2PermissionScopes) | Where-Object { $null -ne $_ }
)
$gatewayScope = Ensure-DelegatedScope $scopes 'gateway_access' 'Access agentgateway' 'Call agentgateway on behalf of the signed-in user.'
$mcpScope = Ensure-DelegatedScope $scopes 'mcp_access' 'Access agentgateway MCP tools' 'Call agentgateway MCP tools on behalf of the signed-in user.'

$preAuthorized = [System.Collections.ArrayList]@(
  @($apiState.api.preAuthorizedApplications) | Where-Object { $null -ne $_ }
)
function Ensure-Preauthorization([string]$ClientId, [string[]]$PermissionIds) {
  $entry = $script:preAuthorized | Where-Object { $_.appId -eq $ClientId } | Select-Object -First 1
  if (-not $entry) {
    [void]$script:preAuthorized.Add([pscustomobject]@{
      appId = $ClientId
      delegatedPermissionIds = @($PermissionIds)
    })
  } else {
    $entry.delegatedPermissionIds = @($entry.delegatedPermissionIds + $PermissionIds | Sort-Object -Unique)
  }
}
Ensure-Preauthorization '04b07795-8ddb-461a-bbee-02f9e1bf7b46' @($gatewayScope.id, $mcpScope.id)
Ensure-Preauthorization 'aebc6443-996d-45c2-90f0-388ff96faa56' @($mcpScope.id)

$roles = [System.Collections.ArrayList]@(
  @($apiState.appRoles) | Where-Object { $null -ne $_ }
)
$appRole = $roles | Where-Object { $_.value -eq 'gateway.invoke' } | Select-Object -First 1
if (-not $appRole) {
  $appRole = [pscustomobject]@{
    id = [guid]::NewGuid().ToString()
    value = 'gateway.invoke'
    displayName = 'Invoke agentgateway'
    description = 'Allows an application or managed identity to invoke agentgateway.'
    allowedMemberTypes = @('Application')
    isEnabled = $true
  }
  [void]$roles.Add($appRole)
} else {
  $appRole.isEnabled = $true
  $appRole.allowedMemberTypes = @($appRole.allowedMemberTypes + 'Application' | Sort-Object -Unique)
}

$identifierUris = @($apiState.identifierUris)
if ($identifierUris -notcontains $apiAudience) { $identifierUris += $apiAudience }
$apiConfig = if ($apiState.api) { $apiState.api } else { [pscustomobject]@{} }
$existingPreAuthorized = @($apiState.api.preAuthorizedApplications)
Set-ObjectProperty $apiConfig 'requestedAccessTokenVersion' 2
Set-ObjectProperty $apiConfig 'oauth2PermissionScopes' @($scopes)
# Graph requires newly created delegated permissions to exist before they can
# be referenced by preauthorized clients.
Set-ObjectProperty $apiConfig 'preAuthorizedApplications' $existingPreAuthorized
$apiPatch = @{
  signInAudience = 'AzureADMyOrg'
  isFallbackPublicClient = $true
  identifierUris = $identifierUris
  publicClient = @{
    redirectUris = @(
      @($apiState.publicClient.redirectUris) +
      @('http://localhost', 'http://127.0.0.1') |
      Sort-Object -Unique
    )
  }
  web = @{
    redirectUris = @(
      @($apiState.web.redirectUris) +
      @('https://vscode.dev/redirect') |
      Sort-Object -Unique
    )
  }
  api = $apiConfig
  appRoles = @($roles)
}
$patchFile = Join-Path $PSScriptRoot ".preprovision-entra-patch-$PID.json"
try {
  $apiPatch | ConvertTo-Json -Depth 20 | Set-Content -Path $patchFile -Encoding utf8
  az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId" `
    --headers 'Content-Type=application/json' `
    --body "@$patchFile" | Out-Null

  $updatedApiState = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId`?`$select=api" `
    -o json | ConvertFrom-Json
  $updatedApiConfig = if ($updatedApiState.api) { $updatedApiState.api } else { [pscustomobject]@{} }
  Set-ObjectProperty $updatedApiConfig 'preAuthorizedApplications' @($preAuthorized)
  @{ api = $updatedApiConfig } |
    ConvertTo-Json -Depth 20 |
    Set-Content -Path $patchFile -Encoding utf8
  az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$apiObjectId" `
    --headers 'Content-Type=application/json' `
    --body "@$patchFile" | Out-Null
} finally {
  Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
}
Write-Host '    configured v2 tokens, delegated scopes, preauthorized clients, and application role'

Write-Host '→ Ensuring the confidential agentgateway UI application...'
$uiAppId = Ensure-Application $uiDisplayName
$uiObjectId = az ad app show --id $uiAppId --query id -o tsv
$uiSpObjectId = az ad sp show --id $uiAppId --query id -o tsv
$uiState = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/applications/$uiObjectId`?`$select=web" `
  -o json | ConvertFrom-Json
$webConfig = if ($uiState.web) { $uiState.web } else { [pscustomobject]@{} }
Set-ObjectProperty $webConfig 'implicitGrantSettings' ([pscustomobject]@{
  enableAccessTokenIssuance = $false
  enableIdTokenIssuance = $false
})
$uiPatch = @{
  signInAudience = 'AzureADMyOrg'
  web = $webConfig
}
try {
  $uiPatch | ConvertTo-Json -Depth 10 | Set-Content -Path $patchFile -Encoding utf8
  az rest --method PATCH `
    --uri "https://graph.microsoft.com/v1.0/applications/$uiObjectId" `
    --headers 'Content-Type=application/json' `
    --body "@$patchFile" | Out-Null
} finally {
  Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
}

$secretOwnerPrefix = "azd:$($env:AZURE_ENV_NAME):agentgateway-ui:"
$secretDisplayName = "$secretOwnerPrefix$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
$uiClientSecret = az ad app credential reset `
  --id $uiAppId `
  --append `
  --years 1 `
  --display-name $secretDisplayName `
  --query password -o tsv

$credentials = az ad app credential list --id $uiAppId -o json | ConvertFrom-Json
$newCredential = $credentials |
  Where-Object { $_.displayName -eq $secretDisplayName } |
  Sort-Object startDateTime -Descending |
  Select-Object -First 1
if (-not $newCredential) { throw 'Could not identify the newly created azd-owned UI credential.' }
foreach ($credential in @($credentials)) {
  if ($credential.displayName.StartsWith($secretOwnerPrefix) -and $credential.keyId -ne $newCredential.keyId) {
    az ad app credential delete --id $uiAppId --key-id $credential.keyId | Out-Null
  }
}
Write-Host '    rotated the UI secret and pruned only credentials owned by this azd environment'

$oidcCookieSecret = Get-AzdValue 'AGENTGATEWAY_OIDC_COOKIE_SECRET'
if ($oidcCookieSecret -notmatch '^[0-9a-fA-F]{64}$') {
  $bytes = [byte[]]::new(32)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $oidcCookieSecret = [Convert]::ToHexString($bytes).ToLowerInvariant()
  Write-Host '    generated a new OIDC cookie secret'
} else {
  Write-Host '    reused the existing OIDC cookie secret'
}

Set-AzdValue 'AGENTGATEWAY_API_CLIENT_ID' $apiAppId
Set-AzdValue 'AGENTGATEWAY_API_OBJECT_ID' $apiObjectId
Set-AzdValue 'AGENTGATEWAY_API_SP_OBJECT_ID' $apiSpObjectId
Set-AzdValue 'AGENTGATEWAY_API_AUDIENCE' $apiAudience
Set-AzdValue 'AGENTGATEWAY_GATEWAY_SCOPE' "$apiAudience/gateway_access"
Set-AzdValue 'AGENTGATEWAY_GATEWAY_SCOPE_ID' $gatewayScope.id
Set-AzdValue 'AGENTGATEWAY_MCP_SCOPE' "$apiAudience/mcp_access"
Set-AzdValue 'AGENTGATEWAY_MCP_SCOPE_ID' $mcpScope.id
Set-AzdValue 'AGENTGATEWAY_APP_ROLE_ID' $appRole.id
Set-AzdValue 'AGENTGATEWAY_APP_ROLE_VALUE' 'gateway.invoke'
Set-AzdValue 'AGENTGATEWAY_UI_CLIENT_ID' $uiAppId
Set-AzdValue 'AGENTGATEWAY_UI_OBJECT_ID' $uiObjectId
Set-AzdValue 'AGENTGATEWAY_UI_SP_OBJECT_ID' $uiSpObjectId
Set-AzdValue 'AGENTGATEWAY_UI_CLIENT_SECRET' $uiClientSecret
Set-AzdValue 'AGENTGATEWAY_OIDC_COOKIE_SECRET' $oidcCookieSecret

Write-Host '✓ Agentgateway Entra IDs, audiences, scopes, role, and secrets were written to the azd environment.'
