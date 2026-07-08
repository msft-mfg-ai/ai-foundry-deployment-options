/// APIM AI Gateway — Developer SKU, Internal VNet injection for Azure AI Foundry.
/// Creates APIM in Internal VNet (Developer SKU), configures private DNS, sets up
/// the inference API and Foundry connections. Uses the modular v2 pattern:
/// v2/apim.bicep → apim-dns.bicep → common-apim-setup.bicep → connections-apim-gateway.bicep.

import { foundryInstanceType } from 'advanced/types.bicep'
import { subscriptionType } from 'v2/apim.bicep'

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceId string
param appInsightsInstrumentationKey string = ''
param appInsightsId string = ''
param resourceToken string
param foundryInstances foundryInstanceType[]
param foundryProjectNames string[] = []
param foundryName string
param subnetResourceId string
param vnetResourceId string

@description('Tenant IDs whose Entra ID tokens the gateway should accept on inbound calls. Empty = no inbound JWT validation.')
param acceptedTenantIds string[] = []

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

module apim 'v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    tags: tags
    location: location
    apimSku: 'Developer'
    lawId: logAnalyticsWorkspaceId
    appInsightsId: appInsightsId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    publicNetworkAccess: 'Enabled'
  }
}

module apimDns 'apim-dns.bicep' = {
  name: 'apim-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apim.outputs.apimPrivateIp
    vnetResourceIds: [vnetResourceId]
    apimName: apim.outputs.name
  }
}

module common_ai_gateway_setup 'common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  params: {
    apimName: apim.outputs.name
    apimLoggerId: apim.outputs.loggerId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsResourceId: appInsightsId
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    acceptedTenantIds: acceptedTenantIds
    foundryInstances: foundryInstances
    apimSku: 'Developer'
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
    apimResourceId: apim.outputs.id
    apimSubscriptionNames: map(subscriptions, s => s.name)
    inferenceApiName: common_ai_gateway_setup.outputs.inferenceApiName
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
      principalId: apim.outputs.principalId
      roleName: 'Cognitive Services User'
    }
  }
]

output apimResourceId string = apim.outputs.id
output apimName string = apim.outputs.name
output apimGatewayUrl string = apim.outputs.gatewayUrl
output apimPrincipalId string = apim.outputs.principalId
output apimAppInsightsLoggerId string = apim.outputs.appInsightsLoggerId
