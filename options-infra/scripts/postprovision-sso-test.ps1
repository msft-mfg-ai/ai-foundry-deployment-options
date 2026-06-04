# postprovision-sso-test.ps1
# ---------------------------------------------------------------------------
# Non-fatal diagnostics for the Teams SSO Bot Service OAuth connection.
# This hook is intentionally read-only and always exits 0 so azd up is not
# blocked for non-admin/operator environments.
# ---------------------------------------------------------------------------
param([switch]$DryRun)

$ErrorActionPreference = 'Continue'
$connectionName = 'foundry-sso'
$warnCount = 0
$passCount = 0

function Get-AzdValue([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  $value = azd env get-value $Name 2>$null
  if ($LASTEXITCODE -eq 0) { return $value }
  return ''
}

function Add-Pass([string]$Message) {
  $script:passCount++
  Write-Host "PASS: $Message"
}

function Add-Warn([string]$Message) {
  $script:warnCount++
  Write-Warning "FAIL: $Message"
}

if ($DryRun) {
  Write-Host 'DRY RUN: postprovision SSO test is read-only; executing diagnostics without changing resources.'
}

Write-Host '→ Running Teams SSO OAuth connection sanity check...'
$ssoAppId = Get-AzdValue 'SSO_APP_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$botName = Get-AzdValue 'PROXY_BOT_NAME'
$proxyBotAppId = Get-AzdValue 'PROXY_BOT_APP_ID'

if ([string]::IsNullOrWhiteSpace($botName) -and -not [string]::IsNullOrWhiteSpace($resourceGroup) -and -not [string]::IsNullOrWhiteSpace($proxyBotAppId)) {
  $botName = az bot list -g $resourceGroup --query "[?properties.msaAppId=='$proxyBotAppId'].name | [0]" -o tsv 2>$null
}
if ([string]::IsNullOrWhiteSpace($botName) -and -not [string]::IsNullOrWhiteSpace($resourceGroup) -and -not [string]::IsNullOrWhiteSpace($proxyBotAppId)) {
  $botName = az resource list -g $resourceGroup --resource-type Microsoft.BotService/botServices --query "[?properties.msaAppId=='$proxyBotAppId'].name | [0]" -o tsv 2>$null
}
if ([string]::IsNullOrWhiteSpace($botName) -and -not [string]::IsNullOrWhiteSpace($resourceGroup)) {
  $botName = az bot list -g $resourceGroup --query "[?contains(name, 'proxy')].name | [0]" -o tsv 2>$null
}
if ([string]::IsNullOrWhiteSpace($botName) -and -not [string]::IsNullOrWhiteSpace($resourceGroup)) {
  $botName = az resource list -g $resourceGroup --resource-type Microsoft.BotService/botServices --query "[?contains(name, 'proxy')].name | [0]" -o tsv 2>$null
}

if ([string]::IsNullOrWhiteSpace($ssoAppId)) { Add-Warn 'SSO_APP_ID is not set in azd env' }
if ([string]::IsNullOrWhiteSpace($resourceGroup)) { Add-Warn 'AZURE_RESOURCE_GROUP is not set in azd env' }
if ([string]::IsNullOrWhiteSpace($botName)) { Add-Warn 'PROXY_BOT_NAME is not set and no proxy bot could be inferred' }

if ([string]::IsNullOrWhiteSpace($ssoAppId) -or [string]::IsNullOrWhiteSpace($resourceGroup) -or [string]::IsNullOrWhiteSpace($botName)) {
  Write-Host "Summary: $passCount passed, $warnCount failed/warned. This diagnostic is non-fatal."
  exit 0
}

try {
  $providersResponse = az bot authsetting list-providers -o json 2>$null | ConvertFrom-Json
  $providers = if ($providersResponse.value) { @($providersResponse.value) } else { @($providersResponse) }
  if ($providers | Where-Object { $_.properties.displayName -eq 'Azure Active Directory v2' -or $_.displayName -eq 'Azure Active Directory v2' -or $_.name -eq 'Azure Active Directory v2' }) {
    Add-Pass "Bot auth provider 'Azure Active Directory v2' is available"
  } else {
    Add-Warn "Bot auth provider 'Azure Active Directory v2' was not found"
  }
} catch {
  Add-Warn "Could not list Bot auth providers: $($_.Exception.Message)"
}

try {
  $settings = az bot authsetting show -g $resourceGroup -n $botName -c $connectionName -o json 2>$null | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or -not $settings) { throw "OAuth connection '$connectionName' was not found" }

  $props = $settings.properties
  function Pick-Setting([string[]]$Names) {
    foreach ($source in @($settings, $props)) {
      if (-not $source) { continue }
      foreach ($name in $Names) {
        if ($source.PSObject.Properties.Name -contains $name) {
          $value = $source.$name
          if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        }
      }
    }
    return $null
  }
  function Get-ParameterValue([string]$Name) {
    foreach ($source in @($settings, $props)) {
      if (-not $source -or -not $source.parameters) { continue }
      foreach ($item in @($source.parameters)) {
        if ($item.key -eq $Name -or $item.name -eq $Name) { return [string]$item.value }
      }
    }
    return $null
  }

  $expectedTokenExchangeUrl = "api://botid-$ssoAppId"
  $clientSecret = Pick-Setting @('clientSecret')
  if (-not [string]::IsNullOrWhiteSpace($clientSecret) -and $clientSecret.ToLowerInvariant() -ne 'null') { Add-Pass 'clientSecret is non-empty' } else { Add-Warn 'clientSecret is non-empty' }
  if ((Pick-Setting @('clientId')) -eq $ssoAppId) { Add-Pass 'clientId matches SSO_APP_ID' } else { Add-Warn 'clientId matches SSO_APP_ID' }
  $tokenExchangeUrl = Pick-Setting @('tokenExchangeUrl')
  if ([string]::IsNullOrWhiteSpace($tokenExchangeUrl)) { $tokenExchangeUrl = Get-ParameterValue 'tokenExchangeUrl' }
  if ($tokenExchangeUrl -eq $expectedTokenExchangeUrl) { Add-Pass 'tokenExchangeUrl matches api://botid-<sso-app-id>' } else { Add-Warn 'tokenExchangeUrl matches api://botid-<sso-app-id>' }
  $scopes = ((Pick-Setting @('scopes')) -split '\s+') | Where-Object { $_ }
  if ($scopes -contains 'https://ai.azure.com/user_impersonation' -and $scopes -contains 'offline_access') {
    Add-Pass 'scopes include Foundry user_impersonation and offline_access'
  } else {
    Add-Warn 'scopes include Foundry user_impersonation and offline_access'
  }
} catch {
  Add-Warn "OAuth connection '$connectionName' could not be validated on bot '$botName' in resource group '$resourceGroup': $($_.Exception.Message)"
}

if ($warnCount -eq 0) {
  Write-Host "Summary: PASS ($passCount checks passed)."
} else {
  Write-Host "Summary: $passCount passed, $warnCount failed/warned. This diagnostic is non-fatal."
}
exit 0
