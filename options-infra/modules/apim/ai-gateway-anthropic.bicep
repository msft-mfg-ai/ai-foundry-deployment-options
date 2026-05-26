// Anthropic-only AI Gateway orchestrator.
// Deploys APIM (Standardv2) with private endpoint and routes traffic to a Foundry-hosted
// Claude endpoint using API-key backend credentials (suitable for cross-tenant scenarios).
// No OpenAI inference API is exposed; only the Anthropic pass-through API is created.

import { aiServiceConfigType } from 'v2/inference-api.bicep'
import { ModelType } from '../ai/connection-apim-gateway.bicep'
import { subscriptionType } from 'v2/apim.bicep'

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceId string
param appInsightsInstrumentationKey string = ''
param appInsightsId string = ''
param aiFoundryName string
param aiFoundryProjectNames string[] = []
param resourceToken string

param anthropicServicesConfig aiServiceConfigType[]
param anthropicStaticModels ModelType[] = []

@secure()
param anthropicApiKey string

param subnetResourceId string
param peSubnetResourceId string
param apimPublicEnabled bool = false

@allowed(['ApiKey', 'ProjectManagedIdentity'])
param authType string = 'ApiKey'

var connection_per_project = !empty(aiFoundryProjectNames)
var subscriptions subscriptionType[] = connection_per_project
  ? map(aiFoundryProjectNames, (projectName) => {
      name: 'sub-${projectName}-${resourceToken}'
      displayName: 'Subscription for ${projectName} in ${aiFoundryName}'
    })
  : [
      {
        name: 'sub-foundry-${aiFoundryName}'
        displayName: 'Default Subscription for ${aiFoundryName}'
      }
    ]

module apim 'apim.bicep' = {
  name: 'apim-deployment'
  params: {
    tags: tags
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
    resourceSuffix: resourceToken
    aiServicesConfig: [] // Anthropic-only: no OpenAI backends
    anthropicServicesConfig: anthropicServicesConfig
    anthropicApiKey: anthropicApiKey
    apimSku: 'Standardv2'
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    // Public access cannot be disabled during initial create; disabled via apim_update after PE.
    publicNetworkAccess: null
    subscriptions: subscriptions
  }
}

module apim_pe 'apim-pe.bicep' = {
  name: 'apim-pe-deployment'
  params: {
    tags: tags
    location: location
    apimName: apim.outputs.apimName
    peSubnetResourceId: peSubnetResourceId
  }
}

// Second pass: disable public access now that the private endpoint is attached.
module apim_update 'apim.bicep' = if (!apimPublicEnabled) {
  name: 'apim-update-deployment'
  params: {
    tags: tags
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
    resourceSuffix: resourceToken
    aiServicesConfig: []
    anthropicServicesConfig: anthropicServicesConfig
    anthropicApiKey: anthropicApiKey
    apimSku: 'Standardv2'
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    publicNetworkAccess: 'Disabled'
    subscriptions: subscriptions
  }
  dependsOn: [apim_pe]
}

// Account-level Anthropic connection (used when there are no per-project connections).
module aiGatewayAnthropicConnectionStatic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project && !empty(anthropicStaticModels)) {
  name: 'apim-anthropic-connection-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-anthropic-static'
    apimResourceId: apim.outputs.apimResourceId
    apiName: apim.outputs.anthropicApiName
    apimSubscriptionName: authType == 'ApiKey' ? first(apim.outputs.subscriptions).name : null
    isSharedToAll: true
    staticModels: anthropicStaticModels
    deploymentInPath: 'false' // Claude model is in the request body, not the URL path
    authType: authType
  }
}

// Per-project Anthropic connections (one subscription key per project for cost tracking).
module aiGatewayAnthropicProjectConnectionStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(anthropicStaticModels)) {
    name: 'apim-anthropic-connection-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-anthropic-static-for-${projectName}'
      apimResourceId: apim.outputs.apimResourceId
      apiName: apim.outputs.anthropicApiName
      apimSubscriptionName: authType == 'ApiKey'
        ? first(filter(apim.outputs.subscriptions, (sub) => contains(sub.name, projectName))).name
        : null
      isSharedToAll: false
      staticModels: anthropicStaticModels
      deploymentInPath: 'false'
      authType: authType
    }
  }
]

module public_mcps './public-mcps.bicep' = {
  name: 'public-mcps-deployment'
  params: {
    apimServiceName: apim.outputs.apimName
    aiFoundryName: aiFoundryName
    apimAppInsightsLoggerId: apim.outputs.apimAppInsightsLoggerId
  }
}

output apimResourceId string = apim.outputs.apimResourceId
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output apimPrincipalId string = apim.outputs.apimPrincipalId
output apimAppInsightsLoggerId string = apim.outputs.apimAppInsightsLoggerId
