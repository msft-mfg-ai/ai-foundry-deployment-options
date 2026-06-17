/// APIM AI Gateway with Private Endpoint for Azure AI Foundry.
/// Creates APIM in External VNet (Standardv2 SKU), attaches a private endpoint, then
/// optionally disables public network access. Uses the modular v2 pattern:
/// v2/apim.bicep → apim-pe.bicep → common-apim-setup.bicep → connections-apim-gateway.bicep.

import { subscriptionType } from 'v2/apim.bicep'
import { foundryInstanceType } from '../apim/advanced/types.bicep'

param location string = resourceGroup().location
param tags object = {}
param foundryProjectNames string[] = []
param acceptedTenantIds string[] = []
param foundryName string
param foundryInstances foundryInstanceType[]

param logAnalyticsWorkspaceId string
param appInsightsInstrumentationKey string = ''
param appInsightsId string = ''
param resourceToken string

param subnetResourceId string
param peSubnetResourceId string
@description('Flag to enable public access to the API Management service')
param apimPublicEnabled bool = false

var connectionPerProject = !empty(foundryProjectNames)
var subscriptions subscriptionType[] = connectionPerProject
  ? map(foundryProjectNames, (projectName) => {
      name: 'sub-${projectName}-${resourceToken}'
      displayName: 'Subscription for ${projectName} in ${foundryName}'
    })
  : [
      {
        name: 'sub-foundry-${foundryName}'
        displayName: 'Default Subscription for ${foundryName}'
      }
    ]

module ai_gateway '../apim/v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    tags: tags
    location: location
    apimSku: 'Standardv2'
    lawId: logAnalyticsWorkspaceId
    appInsightsId: appInsightsId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    #disable-next-line BCP036
    publicNetworkAccess: 'Enabled'
  }
}

module apimPrivateEndpoint '../apim/apim-pe.bicep' = {
  name: 'apim-pe-deployment'
  params: {
    tags: tags
    location: location
    apimName: ai_gateway.outputs.name
    peSubnetResourceId: peSubnetResourceId
  }
}

module common_ai_gateway_setup '../apim/common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  params: {
    apimName: ai_gateway.outputs.name
    apimLoggerId: ai_gateway.outputs.loggerId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsResourceId: appInsightsId
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    acceptedTenantIds: acceptedTenantIds
    foundryInstances: foundryInstances
    apimSku: 'Standardv2'
  }
}

module foundry_connections '../ai/connections-apim-gateway.bicep' = {
  name: 'apim-connections-for-foundry'
  params: {
    aiFoundryName: foundryName
    aiFoundryProjectNames: foundryProjectNames
    resourceToken: resourceToken
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    staticModels: common_ai_gateway_setup.outputs.staticModels
    apimResourceId: ai_gateway.outputs.id
    apimSubscriptionNames: map(subscriptions, s => s.name)
    inferenceApiName: common_ai_gateway_setup.outputs.inferenceApiName
  }
}

module apimServiceUpdate '../apim/v2/apim.bicep' = if (!apimPublicEnabled) {
  name: 'apim-update-deployment'
  dependsOn: [
    apimPrivateEndpoint
    common_ai_gateway_setup
    foundry_connections
  ]
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    location: location
    tags: tags
    apimSku: 'Standardv2'
    lawId: logAnalyticsWorkspaceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    publicNetworkAccess: 'Disabled'
  }
}

// Grant APIM's managed identity Cognitive Services User on every backing
// Foundry instance. Skip chained-APIM instances (isApim=true): they auth
// inbound via JWT, not via RBAC.
module apim_role_assignments '../iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'apim-role-${i}-${resourceToken}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: ai_gateway.outputs.principalId
      roleName: 'Cognitive Services User'
    }
  }
]
output apimResourceId string = ai_gateway.outputs.id
output apimName string = ai_gateway.outputs.name
output apimGatewayUrl string = ai_gateway.outputs.gatewayUrl
output apimPrincipalId string = ai_gateway.outputs.principalId
output apimAppInsightsLoggerId string = ai_gateway.outputs.appInsightsLoggerId

@description('Realtime WebSocket API path (e.g. `inference/openai/realtime`). Empty when no realtime model deployment is fronted by the gateway.')
output realtimeApiPath string = common_ai_gateway_setup.outputs.realtimeApiPath
@description('Full wss URL of the realtime API, or empty when no realtime model is available.')
output realtimeUrl string = empty(common_ai_gateway_setup.outputs.realtimeApiPath)
  ? ''
  : '${replace(ai_gateway.outputs.gatewayUrl, 'https:', 'wss:')}/${common_ai_gateway_setup.outputs.realtimeApiPath}'
