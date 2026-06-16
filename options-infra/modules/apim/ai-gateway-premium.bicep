/// APIM AI Gateway — Premiumv2 SKU, Internal VNet injection with custom domain for Azure AI Foundry.
/// Creates APIM Premiumv2 in Internal VNet, configures private DNS (default + custom domain),
/// sets up the inference API and Foundry connections, then applies hostname/cert configuration.
/// Uses the modular v2 pattern:
/// v2/apim.bicep → apim-dns.bicep (x2) → common-apim-setup.bicep →
/// connections-apim-gateway.bicep → apim-hostname-update.bicep.

import { foundryInstanceType } from 'advanced/types.bicep'
import { subscriptionType, hostnameConfigurationType } from 'v2/apim.bicep'

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

@description('VNet resource IDs to link to the APIM private DNS zones (typically both the APIM VNet and the Foundry VNet).')
param vnetResourceIds string[]

@description('Tenant IDs whose Entra ID tokens the gateway should accept on inbound calls. Empty = no inbound JWT validation.')
param acceptedTenantIds string[] = []

@description('User-assigned managed identity resource ID for APIM (used for Key Vault cert access).')
param apimUserAssignedManagedIdentityResourceId string

@description('Hostname configurations for the APIM service (proxy, developer portal, etc.).')
param hostnameConfigurations hostnameConfigurationType[] = []

@description('Custom domain name used to create the custom DNS A record (e.g. cloud.contoso.org → apim.<customDomain>). Leave empty to skip custom DNS zone.')
param customDomain string = ''

@description('Key Vault name that holds the TLS certificate. Required when hostnameConfigurations is non-empty.')
param keyVaultName string = ''

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
    resourceSuffix: resourceToken
    apimSku: 'Premiumv2'
    lawId: logAnalyticsWorkspaceId
    appInsightsId: appInsightsId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    apimManagedIdentityType: 'SystemAssigned, UserAssigned'
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    hostnameConfigurations: hostnameConfigurations
    publicNetworkAccess: 'Enabled'
  }
}

module apimDns 'apim-dns.bicep' = {
  name: 'apim-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apim.outputs.apimPrivateIp
    vnetResourceIds: vnetResourceIds
    apimName: apim.outputs.name
  }
}

module apimCustomDns 'apim-dns.bicep' = if (!empty(customDomain)) {
  name: 'apim-custom-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apim.outputs.apimPrivateIp
    vnetResourceIds: vnetResourceIds
    apimName: 'apim'
    zoneName: customDomain
  }
}

module common_ai_gateway_setup 'common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  params: {
    apimName: apim.outputs.name
    apimLoggerId: apim.outputs.loggerId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsResourceId: appInsightsId
    resourceToken: resourceToken
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    acceptedTenantIds: acceptedTenantIds
    foundryInstances: foundryInstances
    apimSku: 'Premiumv2'
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

module apimHostnameUpdate 'apim-hostname-update.bicep' = if (!empty(hostnameConfigurations)) {
  name: 'apim-hostname-update-deployment'
  dependsOn: [
    apimDns
    apimCustomDns
    common_ai_gateway_setup
    foundry_connections
  ]
  params: {
    tags: tags
    location: location
    resourceSuffix: resourceToken
    apimSku: 'Premiumv2'
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    #disable-next-line BCP036
    publicNetworkAccess: null
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    apimManagedIdentityType: 'SystemAssigned, UserAssigned'
    apimPrincipalId: apim.outputs.principalId
    hostnameConfigurations: hostnameConfigurations
    keyVaultName: keyVaultName
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
