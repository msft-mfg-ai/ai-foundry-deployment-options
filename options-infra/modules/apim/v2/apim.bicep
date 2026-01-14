/**
 * @module apim-v2
 * @description This module defines the Azure API Management (APIM) resources using Bicep.
 * It includes configurations for creating and managing APIM instance.
 * This is version 2 (v2) of the APIM Bicep module.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The suffix to append to the API Management instance name. Defaults to a unique string based on subscription and resource group IDs.')
param resourceSuffix string = uniqueString(subscription().id, resourceGroup().id)

@description('The name of the API Management instance. Defaults to "apim-<resourceSuffix>".')
param apiManagementName string = 'apim-${resourceSuffix}'

@description('The location of the API Management instance. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The email address of the publisher. Defaults to "noreply@microsoft.com".')
param publisherEmail string = 'noreply@microsoft.com'

@description('The name of the publisher. Defaults to "Microsoft".')
param publisherName string = 'Microsoft'

@description('The pricing tier of this API Management service')
@allowed([
  'Consumption'
  'Developer'
  'Basic'
  'Basicv2'
  'Standard'
  'Standardv2'
  'Premium'
  'Premiumv2'
])
param apimSku string = 'Basicv2'

@description('The type of managed identity to by used with API Management')
@allowed([
  'SystemAssigned'
  'UserAssigned'
  'SystemAssigned, UserAssigned'
])
param apimManagedIdentityType string = 'SystemAssigned'

@description('The user-assigned managed identity ID to be used with API Management')
param apimUserAssignedManagedIdentityResourceId string?

@description('Configuration array for APIM subscriptions')
param apimSubscriptionsConfig subscriptionType[] = []

@description('The Log Analytics Workspace ID for diagnostic settings')
param lawId string = ''

@description('The instrumentation key for Application Insights')
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights')
param appInsightsId string = ''

@description('The release channel for the API Management service')
@allowed([
  'Early'
  'Default'
  'Late'
  'GenAI'
])
param releaseChannel string = 'Default'

@allowed([
  'External'
  'Internal'
  'None'
])
param virtualNetworkType string = 'None'
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
param subnetResourceId string?
@description('Custom domain hostname configurations for the API Management service')
param hostnameConfigurations hostnameConfigurationType[] = []
param tags object = {}

// ------------------
//    TYPE DEFINITIONS
// ------------------
@export()
type subscriptionType = {
  @description('The name of the subscription.')
  name: string
  @description('Display name of the subscription.')
  displayName: string
}

@export()
type hostnameConfigurationType = {
  @description('The type of hostname configuration.')
  type: 'Management' | 'Portal' | 'Proxy' | 'Scm' | 'DeveloperPortal'
  @description('The custom host name.')
  hostName: string
  @description('The source of the certificate.')
  certificateSource: 'KeyVault' | 'Default'
  @description('The Key Vault ID containing the certificate.')
  keyVaultId: string
}

// ------------------
//    VARIABLES
// ------------------

// split managed identity resource ID to get the name
var identityParts = split(apimUserAssignedManagedIdentityResourceId ?? '', '/')
// get the name of the managed identity
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

var custom_domain_check = !empty(hostnameConfigurations) && empty(apimUserAssignedManagedIdentityResourceId)
  ? fail('If hostnameConfigurations with customDomain are provided - apimUserAssignedManagedIdentityResourceId must also be provided.')
  : true

// Setting up custom domains for SkuType PremiumV2 currently is only supported for 'Proxy' and 'DeveloperPortal' hostname type.
var effective_hostname_configurations = map(
  hostnameConfigurations,
  (config) => union(config, { identityClientId: apimUserAssignedManagedIdentityResourceId })
)
// ------------------
//    RESOURCES
// ------------------

resource apim_identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(apimUserAssignedManagedIdentityResourceId)) {
  name: managedIdentityName
}

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service
// 2025-03-01-preview?  
// https://learn.microsoft.com/en-us/azure/templates/microsoft.apimanagement/2025-03-01-preview/service?pivots=deployment-language-bicep
resource apimService 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apiManagementName
  location: location
  tags: tags
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    releaseChannel: releaseChannel
    virtualNetworkType: virtualNetworkType
    virtualNetworkConfiguration: empty(subnetResourceId)
      ? null
      : {
          subnetResourceId: subnetResourceId
        }
    publicNetworkAccess: publicNetworkAccess
    hostnameConfigurations: effective_hostname_configurations
  }
  identity: {
    type: apimManagedIdentityType
    userAssignedIdentities: apimManagedIdentityType == 'UserAssigned' && !empty(apimUserAssignedManagedIdentityResourceId)
      ? {
          // BCP037: Not yet added to latest API:
          '${apimUserAssignedManagedIdentityResourceId}': {}
        }
      : null
  }
}

resource apimDiagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (length(lawId) > 0) {
  scope: apimService
  name: 'apimDiagnosticSettings'
  properties: {
    workspaceId: lawId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'AllLogs'
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

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = if (length(lawId) > 0) {
  parent: apimService
  name: 'azuremonitor'
  properties: {
    loggerType: 'azureMonitor'
    isBuffered: false // Set to false to ensure logs are sent immediately
  }
}

// Create a logger only if we have an App Insights ID and instrumentation key.
resource apimAppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2021-12-01-preview' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  name: 'appinsights-logger'
  parent: apimService
  properties: {
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
    description: 'APIM Logger for Application Insights'
    isBuffered: false
    loggerType: 'applicationInsights'
    resourceId: appInsightsId
  }
}

@batchSize(1)
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = [
  for subscription in apimSubscriptionsConfig: if (length(apimSubscriptionsConfig) > 0) {
    name: subscription.name
    parent: apimService
    properties: {
      allowTracing: true
      displayName: subscription.displayName
      scope: '/apis'
      state: 'active'
    }
  }
]

// ------------------
//    OUTPUTS
// ------------------

output id string = apimService.id
output name string = apimService.name
output principalId string = contains(apimManagedIdentityType, 'SystemAssigned')
  ? apimService.identity.principalId
  : apim_identity.?properties.principalId ?? ''
output gatewayUrl string = apimService.properties.gatewayUrl
output loggerId string = (length(lawId) > 0) ? apimLogger.id : ''
output appInsightsLoggerId string = (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey))
  ? apimAppInsightsLogger.id
  : ''
output apimPrivateIp string = apimService.properties.privateIPAddresses != null && length(apimService.properties.privateIPAddresses) > 0
  ? apimService.properties.privateIPAddresses[0]
  : ''
output apimPublicIp string = apimService.properties.publicIPAddresses != null && length(apimService.properties.publicIPAddresses) > 0
  ? apimService.properties.publicIPAddresses[0]
  : ''
output apimCustomDomainSetupOk bool = custom_domain_check

#disable-next-line outputs-should-not-contain-secrets
output apimSubscriptions array = [
  for (subscription, i) in apimSubscriptionsConfig: {
    name: subscription.name
    displayName: subscription.displayName
    key: apimSubscription[i].listSecrets().primaryKey
  }
]
