import { aiServiceConfigType } from 'v2/inference-api.bicep'
import { ModelType } from '../ai/connection-apim-gateway.bicep'
import { subscriptionType, hostnameConfigurationType } from 'v2/apim.bicep'

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceId string
param appInsightsInstrumentationKey string = ''
param appInsightsId string = ''
param aiFoundryName string
param aiFoundryProjectNames string[] = []
param resourceToken string

param staticModels ModelType[] = []
param aiServicesConfig aiServiceConfigType[] = []
param subnetResourceId string
param vnetResourceIdsForDnsLink string[] = []
@description('The user-assigned managed identity ID to be used with API Management')
param apimUserAssignedManagedIdentityResourceId string?
param certificateKeyVaultUri string?
param keyVaultName string?
param customDomain string?

var custom_domain_setup_valid = !empty(customDomain) && (empty(certificateKeyVaultUri) || empty(apimUserAssignedManagedIdentityResourceId) || empty(keyVaultName))
  ? fail('Custom domain requires both certificateKeyVaultUri, apimUserAssignedManagedIdentityResourceId, and keyVaultName to be set.')
  : true

var hostnameConfigurations hostnameConfigurationType[] = custom_domain_setup_valid
  ? [
      // Setting up custom domains for SkuType PremiumV2 currently is only supported for 'Proxy' and 'DeveloperPortal' hostname type.
      {
        type: 'Proxy'
        hostName: 'apim.${customDomain}'
        certificateSource: 'KeyVault'
        keyVaultId: certificateKeyVaultUri!
      }
    ]
  : []
var subnetIdParts = split(subnetResourceId, '/')
var subnetName = last(subnetIdParts)
var vnetResourceId = substring(subnetResourceId, 0, length(subnetResourceId) - length('/subnets/${subnetName}'))

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
    aiServicesConfig: aiServicesConfig
    apimSku: 'Premiumv2'
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    // NotSupported: Blocking all public network access by setting property `publicNetworkAccess` of API Management service apim-xxxx is not enabled during service creation.
    publicNetworkAccess: null
    subscriptions: subscriptions
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    apimManagedIdentityType: 'SystemAssigned, UserAssigned'
  }
}

// run lightweight update to update custom domains only (avoids re-deploying full APIM with APIs)
module apim_update 'apim-hostname-update.bicep' = if (custom_domain_setup_valid && !empty(hostnameConfigurations)) {
  name: 'apim-hostname-update-deployment'
  params: {
    tags: tags
    location: location
    resourceSuffix: resourceToken
    apimSku: 'Premiumv2'
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    // NotSupported: Blocking all public network access by setting property `publicNetworkAccess` of API Management service apim-xxxx is not enabled during service creation.
    publicNetworkAccess: null
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    apimManagedIdentityType: 'SystemAssigned, UserAssigned'
    apimPrincipalId: apim.outputs.apimPrincipalId
    // update only the hostname configurations
    hostnameConfigurations: hostnameConfigurations
    keyVaultName: keyVaultName!
  }
  dependsOn: [apim_dns, apim_custom_dns]
}

module apim_dns 'apim-dns.bicep' = {
  name: 'apim-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apim.outputs.apimPrivateIp
    vnetResourceIds: union(vnetResourceIdsForDnsLink, [vnetResourceId])
    apimName: apim.outputs.apimName
  }
}

module apim_custom_dns 'apim-dns.bicep' = if (!empty(customDomain)) {
  name: 'apim-custom-dns-deployment'
  params: {
    vnetResourceIds: union(vnetResourceIdsForDnsLink, [vnetResourceId])
    apimName: 'apim'
    apimIpAddress: apim.outputs.apimPrivateIp
    zoneName: customDomain
  }
}

module aiGatewayConnectionDynamic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project) {
  name: 'apim-connection-dynamic'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-dynamic'
    apimResourceId: apim.outputs.apimResourceId
    apiName: apim.outputs.inferenceApiName
    apimSubscriptionName: first(apim.outputs.subscriptions).name
    isSharedToAll: true
    listModelsEndpoint: '/deployments'
    getModelEndpoint: '/deployments/{deploymentName}'
    deploymentProvider: 'AzureOpenAI'
    inferenceAPIVersion: '2025-03-01-preview'
    // apim connection doesn't support custom domain
  }
}

module aiGatewayConnectionStatic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project && !empty(staticModels)) {
  name: 'apim-connection-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-static'
    apimResourceId: apim.outputs.apimResourceId
    apiName: apim.outputs.inferenceApiName
    apimSubscriptionName: first(apim.outputs.subscriptions).name
    isSharedToAll: true
    staticModels: staticModels
    inferenceAPIVersion: '2025-03-01-preview'
    // apim connection doesn't support custom domain
  }
}

module aiGatewayProjectConnectionStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(staticModels)) {
    name: 'apim-connection-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-static-for-${projectName}'
      apimResourceId: apim.outputs.apimResourceId
      apiName: apim.outputs.inferenceApiName
      apimSubscriptionName: first(filter(apim.outputs.subscriptions, (sub) => contains(sub.name, projectName))).name
      isSharedToAll: false
      staticModels: staticModels
      inferenceAPIVersion: '2025-03-01-preview'
    // apim connection doesn't support custom domain
    }
  }
]

module aiGatewayProjectConnectionDynamic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project) {
    name: 'apim-connection-dynamic-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-dynamic-for-${projectName}'
      apimResourceId: apim.outputs.apimResourceId
      apiName: apim.outputs.inferenceApiName
      apimSubscriptionName: first(filter(apim.outputs.subscriptions, (sub) => contains(sub.name, projectName))).name
      isSharedToAll: false
      listModelsEndpoint: '/deployments'
      getModelEndpoint: '/deployments/{deploymentName}'
      deploymentProvider: 'AzureOpenAI'
      inferenceAPIVersion: '2025-03-01-preview'
    // apim connection doesn't support custom domain
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

module modelGatewayConnectionStatic '../ai/connection-modelgateway-static.bicep' = [
for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(staticModels)) {
  name: 'model-gateway-connection-static-${projectName}'
  params: {
    aiFoundryName: aiFoundryName
    aiFoundryProjectName: projectName
    connectionName: 'model-gateway-${resourceToken}-static-for-${projectName}'
    apiKey: first(filter(apim.outputs.subscriptions, (sub) => contains(sub.name, projectName))).key
    isSharedToAll: false
    gatewayName: 'apim'
    staticModels: staticModels
    inferenceAPIVersion: '2025-03-01-preview'
    targetUrl: customDomain != null ? 'https://apim.${customDomain}/${apim.outputs.inferenceApiPath}' : apim.outputs.apiUrl
    deploymentInPath: 'true'
  }
}]

module modelGatewayConnectionDynamic '../ai/connection-modelgateway-dynamic.bicep' = [
for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(staticModels)) {
  name: 'model-gateway-connection-dynamic-${projectName}'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'model-gateway-${resourceToken}-dynamic-for-${projectName}'
    apiKey: first(filter(apim.outputs.subscriptions, (sub) => contains(sub.name, projectName))).key
    isSharedToAll: false
    gatewayName: 'apim'
    targetUrl: customDomain != null ? 'https://apim.${customDomain}/${apim.outputs.inferenceApiPath}' : apim.outputs.apiUrl
    listModelsEndpoint: '/deployments'
    getModelEndpoint: '/deployments/{deploymentName}'
    deploymentProvider: 'AzureOpenAI'
    inferenceAPIVersion: '2025-03-01-preview'
    deploymentInPath: 'true'
  }
}]

output customDomainSetupValid bool = custom_domain_setup_valid
output apimResourceId string = apim.outputs.apimResourceId
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output apimPrincipalId string = apim.outputs.apimPrincipalId
output apimAppInsightsLoggerId string = apim.outputs.apimAppInsightsLoggerId
