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
  # Bot Service redacts clientSecret on GET by design (write-only), so a non-null
  # value here means it was set; a null/empty value is the EXPECTED read-back
  # even when the secret is correctly stored. We can't actually verify the
  # secret via az; just note its read-back state for the operator.
  if (-not [string]::IsNullOrWhiteSpace($clientSecret) -and $clientSecret.ToLowerInvariant() -ne 'null') {
    Add-Pass 'clientSecret read-back: set (read-back)'
  } else {
    Add-Pass 'clientSecret read-back: redacted (expected) -- verify via OAuth Connection Test in the portal'
  }
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

# ---------------------------------------------------------------------------
# Deployment summary — explains what was provisioned in Microsoft Entra and
# Bot Service so operators can verify in the portal or replicate the setup
# manually in a tenant where this script can't run.
# ---------------------------------------------------------------------------
$tenantId       = (az account show --query tenantId -o tsv 2>$null)
$subscriptionId = (az account show --query id -o tsv 2>$null)
$containerApp   = Get-AzdValue 'PROXY_CONTAINER_APP_NAME'
if ([string]::IsNullOrWhiteSpace($containerApp) -and -not [string]::IsNullOrWhiteSpace($resourceGroup)) {
  $containerApp = (az resource list -g $resourceGroup --resource-type Microsoft.App/containerApps --query "[?contains(name, 'teams-proxy')].name | [0]" -o tsv 2>$null)
}
$proxyFqdn = ''
if (-not [string]::IsNullOrWhiteSpace($containerApp) -and -not [string]::IsNullOrWhiteSpace($resourceGroup)) {
  $proxyFqdn = (az containerapp show -n $containerApp -g $resourceGroup --query "properties.configuration.ingress.fqdn" -o tsv 2>$null)
}

@"

============================================================================
Microsoft Entra app + Bot Service OAuth -- what was provisioned
============================================================================
This is what the preprovision script set up for Teams SSO. Verify in the
Entra portal, or recreate it manually in a tenant where automation can't
run.

  Microsoft Entra application registration
    Display name              : sso-foundry-teams-$($env:AZURE_ENV_NAME)
    Application (client) ID   : $ssoAppId
    Tenant ID                 : $tenantId
    Sign-in audience          : AzureADMyOrg (single-tenant)
    Application ID URI        : api://botid-$ssoAppId
    Access token version      : 2 (api.requestedAccessTokenVersion)
    Optional claims (access)  : idtyp
    Exposed scope             : access_as_user (delegated, user-consentable)
    Pre-authorized clients    : 1fec8e78-bce4-4aaf-ab1b-5451cc387264  (Teams web)
                                5e3ce6c0-2b1f-4285-8d4b-75ee78787346  (Teams desktop / mobile)
    Required API permissions  : Microsoft Graph                 / User.Read     (Delegated)
                                Azure AI Foundry (ai.azure.com) / user_impersonation (Delegated)
    Web redirect URI          : https://token.botframework.com/.auth/web/redirect
    Client secret             : created and stored in azd env (SSO_APP_SECRET)
    Admin consent             : best-effort granted by the script

  Bot Service OAuth connection (on bot '$botName')
    Connection name           : $connectionName
    Service provider          : Azure Active Directory v2
    Client ID                 : $ssoAppId
    Client secret             : write-only; the same value as SSO_APP_SECRET
    tokenExchangeUrl          : api://botid-$ssoAppId
    Scopes                    : https://ai.azure.com/user_impersonation offline_access

  Container app env (proxy)
    TeamsSso__ConnectionName  : $connectionName
    TeamsSso__AadAppId        : $ssoAppId
    TeamsSso__Resource        : api://botid-$ssoAppId
    TeamsSso__ClientSecret    : (Container Apps secret, sourced from SSO_APP_SECRET)

Next steps
  1. Verify the OAuth connection works:
       Bot Service '$botName' -> Configuration -> OAuth Connection Settings
       -> '$connectionName' -> 'Test connection'. Expect a JWT for aud=https://ai.azure.com.
  2. Generate and install the Teams manifest:
       Open https://$proxyFqdn/admin/manifest
       Paste the bot's Microsoft App ID (the bot's UAMI client id), generate
       the zip, and side-load it into Teams (Apps -> Manage your apps ->
       Upload a custom app).
  3. Open a chat with the bot in Teams. First message triggers silent SSO; on
     a fresh install you may see a one-time consent dialog.

  Portal links (this subscription):
    Entra app:   https://portal.azure.com/#@$tenantId/blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/Overview/appId/$ssoAppId
    Bot Service: https://portal.azure.com/#@$tenantId/resource/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.BotService/botServices/$botName/Configuration
"@ | Write-Host

exit 0
