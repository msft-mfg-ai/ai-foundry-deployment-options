@description('Bot service resource name.')
param name string

@description('Bot Service is a global control-plane resource; location is fixed to "global".')
param location string = 'global'

@description('Tags to apply.')
param tags object = {}

@allowed(['F0', 'S1'])
@description('Bot Service SKU. Microsoft Teams channel requires S1 (Standard) — on the F0 (Free) tier, Teams routing silently does not work even though the channel shows as enabled. Use F0 only when Teams is not needed.')
param sku string = 'S1'

@description('Bot display name shown in channels.')
param displayName string = name

@description('Messaging endpoint (https://...) the bot posts to. For Foundry agents, point at the agent\'s activityprotocol URL.')
param endpoint string

@allowed([
  'SingleTenant'
  'MultiTenant'
  'UserAssignedMSI'
])
@description('Identity model used by the bot. SingleTenant: caller provides an existing `msaAppId` (e.g. a Foundry agent\'s ServiceIdentity appId). UserAssignedMSI: a UAMI is created here and used as both msaAppId and msaAppMSIResourceId.')
param msaAppType string = 'SingleTenant'

@description('AppId baked into the bot. Required for SingleTenant/MultiTenant. For UserAssignedMSI, leave empty (the created UAMI\'s clientId is used).')
param msaAppId string = ''

@description('Tenant id for SingleTenant / UserAssignedMSI. Defaults to the deployment tenant.')
param msaAppTenantId string = tenant().tenantId

@description('Name of the user-assigned managed identity to create when msaAppType = UserAssignedMSI. Ignored when `existingMsiResourceId` + `existingMsiClientId` are supplied. Defaults to "<name>-id".')
param identityName string = '${name}-id'

@description('Resource id of an existing UAMI to use when msaAppType = UserAssignedMSI. When supplied together with `existingMsiClientId`, the module skips creating a new UAMI and reuses this one. Use this to share one identity across multiple bot services (so a downstream endpoint can validate a single `aud`).')
param existingMsiResourceId string = ''

@description('Client id of the existing UAMI matching `existingMsiResourceId`. Required together with it.')
param existingMsiClientId string = ''

@description('Optional Application Insights component name (same resource group) — when set, instrumentation key + app ID are wired into the bot.')
param appInsightsName string = ''

@description('Optional Log Analytics workspace resource ID. When set, a diagnostic setting is created on the bot to ship BotRequest / DependencyRequest / channel logs + AllMetrics to the workspace.')
param logAnalyticsWorkspaceResourceId string = ''

@description('Disable local (key-based) auth on the bot. Portal default is false.')
param disableLocalAuth bool = true

@description('Create the Microsoft Teams channel for this bot.')
param enableTeamsChannel bool = true

@description('Create the Direct Line channel for this bot (used by Web Chat / custom clients).')
param enableDirectLineChannel bool = true

// ---------------------------------------------------------------------------
// Optional Teams SSO OAuth Connection Setting
// ---------------------------------------------------------------------------
// When `ssoConnectionName` + `ssoClientId` + `ssoClientSecret` are all set,
// a `connections` child resource is created that the bot can use via
// `UserTokenClient.GetUserTokenAsync(connectionName=...)`. Bot Service handles
// the OBO swap to the resource named in `ssoScopes` using the AAD app whose
// client id/secret are provided.

@description('Name of the Bot Service OAuth connection setting. When empty, no SSO connection is created.')
param ssoConnectionName string = ''

@description('Client id of the AAD app that owns the SSO scope. Required when `ssoConnectionName` is set.')
param ssoClientId string = ''

@secure()
@description('Client secret of the AAD app. Required when `ssoConnectionName` is set.')
param ssoClientSecret string = ''

@description('Space-separated scopes the connection requests during OBO. Default targets the Foundry data plane.')
param ssoScopes string = 'https://ai.azure.com/user_impersonation offline_access'

@description('Token exchange URL for Teams SSO — typically `api://<sso-app-id>`. Required when `ssoConnectionName` is set.')
param ssoTokenExchangeUrl string = ''

var botServiceLocations = ['westeurope','westus','centralindia']
var botServiceLocation = contains(botServiceLocations, location) ? location : 'global'

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
var requiresExplicitAppId = msaAppType != 'UserAssignedMSI'
var useExistingMsi = msaAppType == 'UserAssignedMSI' && !empty(existingMsiResourceId) && !empty(existingMsiClientId)
var createNewMsi  = msaAppType == 'UserAssignedMSI' && !useExistingMsi
#disable-next-line no-unused-vars
var valid = (requiresExplicitAppId && empty(msaAppId))
  ? fail('msaAppId is required when msaAppType is SingleTenant or MultiTenant.')
  : (msaAppType == 'UserAssignedMSI' && (empty(existingMsiResourceId) != empty(existingMsiClientId)))
    ? fail('existingMsiResourceId and existingMsiClientId must both be supplied or both omitted.')
    : true

// ---------------------------------------------------------------------------
// Optional User-Assigned Managed Identity (only when msaAppType = UserAssignedMSI)
// ---------------------------------------------------------------------------
module botIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = if (createNewMsi) {
  name: '${identityName}-deployment'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Application Insights — optional, read existing component
// ---------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsName)) {
  name: appInsightsName
}

// ---------------------------------------------------------------------------
// Bot
// ---------------------------------------------------------------------------
var effectiveMsiResourceId = useExistingMsi ? existingMsiResourceId : (createNewMsi ? botIdentity!.outputs.resourceId : '')
var effectiveMsiClientId   = useExistingMsi ? existingMsiClientId   : (createNewMsi ? botIdentity!.outputs.clientId   : '')
var effectiveAppId = msaAppType == 'UserAssignedMSI' ? effectiveMsiClientId : msaAppId

var baseProperties = {
  displayName: displayName
  endpoint: endpoint
  msaAppType: msaAppType
  msaAppId: effectiveAppId
  msaAppTenantId: msaAppTenantId
  publicNetworkAccess: 'Enabled'
  disableLocalAuth: disableLocalAuth
  schemaTransformationVersion: '1.3'
  developerAppInsightsApplicationId: empty(appInsightsName) ? null : appInsights!.properties.AppId
  developerAppInsightKey: empty(appInsightsName) ? null : appInsights!.properties.InstrumentationKey
}

var msiProperties = msaAppType == 'UserAssignedMSI' ? {
  msaAppMSIResourceId: effectiveMsiResourceId
} : {}

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: name
  location: botServiceLocation
  tags: tags
  kind: 'azurebot'
  sku: {
    name: sku
  }
  properties: union(baseProperties, msiProperties)
  
}

resource teamsChannel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = if (enableTeamsChannel) {
  parent: bot
  name: 'MsTeamsChannel'
  location: botServiceLocation
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
    }
  }
}

resource directLineChannel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = if (enableDirectLineChannel) {
  parent: bot
  name: 'DirectLineChannel'
  location: botServiceLocation
  properties: {
    channelName: 'DirectLineChannel'
    properties: {
      sites: [
        {
          siteName: 'Default Site'
          isEnabled: true
          isV1Enabled: true
          isV3Enabled: true
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// SSO OAuth Connection — created only when the caller supplies all three
// required values. Validation matches the C# `TeamsSsoService`'s expectation
// that the connection name and tenant align with the AAD app.
// ---------------------------------------------------------------------------
var enableSso = !empty(ssoConnectionName) && !empty(ssoClientId) && !empty(ssoClientSecret) && !empty(ssoTokenExchangeUrl)

resource ssoConnection 'Microsoft.BotService/botServices/connections@2023-09-15-preview' = if (enableSso) {
  parent: bot
  name: ssoConnectionName
  location: botServiceLocation
  properties: {
    // Fixed GUID for the "Azure Active Directory v2" service provider. The
    // API rejects requests that only set serviceProviderDisplayName.
    serviceProviderId: '30dd229c-58e3-4a48-bdfd-91ec48eb906c'
    serviceProviderDisplayName: 'Azure Active Directory v2'
    clientId: ssoClientId
    clientSecret: ssoClientSecret
    scopes: ssoScopes
    parameters: [
      { key: 'tenantID',         value: msaAppTenantId }
      { key: 'tokenExchangeUrl', value: ssoTokenExchangeUrl }
    ]
  }
}

// ---------------------------------------------------------------------------
// Diagnostic setting — ships bot logs + metrics to Log Analytics.
// `allLogs` captures BotRequest, DependencyRequest, and any future categories.
// ---------------------------------------------------------------------------
resource botDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceResourceId)) {
  name: '${name}-diagnostics'
  scope: bot
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output botResourceId string = bot.id
output botName string = bot.name

@description('The appId configured on the bot (whether passed in or generated from a UAMI). Use this in Teams app manifest as bots[].botId.')
output msaAppId string = effectiveAppId

@description('UAMI resource id — only populated when msaAppType = UserAssignedMSI.')
output identityResourceId string = effectiveMsiResourceId

@description('UAMI clientId — only populated when msaAppType = UserAssignedMSI.')
output identityClientId string = effectiveMsiClientId

@description('UAMI principalId — populated only when this module created the UAMI itself (existing-UAMI mode does not surface principalId).')
output identityPrincipalId string = createNewMsi ? botIdentity!.outputs.principalId : ''

@description('Name of the SSO OAuth connection, or empty when no SSO connection was created. Use this on the container app as `TeamsSso__ConnectionName`.')
output ssoConnectionName string = enableSso ? ssoConnectionName : ''
