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

param staticModels ModelType[] = []
param aiServicesConfig aiServiceConfigType[] = []
param subnetResourceId string
param peSubnetResourceId string
@description('Flag to enable public access to the API Management service')
param apimPublicEnabled bool = false

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
    apimSku: 'Standardv2'
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    // NotSupported: Blocking all public network access by setting property `publicNetworkAccess` of API Management service apim-xxxx is not enabled during service creation.
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

// run update to disable public access if needed
module apim_update 'apim.bicep' = if (!apimPublicEnabled) {
  name: 'apim-update-deployment'
  params: {
    tags: tags
    location: location
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
    resourceSuffix: resourceToken
    aiServicesConfig: aiServicesConfig
    apimSku: 'Standardv2'
    virtualNetworkType: 'External'
    subnetResourceId: subnetResourceId
    // NotSupported: Blocking all public network access by setting property `publicNetworkAccess` of API Management service apim-xxxx is not enabled during service creation.
    // Need to run this weird update step after PE is attached.
    publicNetworkAccess: 'Disabled'
    subscriptions: subscriptions
  }
  dependsOn: [apim_pe]
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

// module modelGatewayConnectionStatic '../ai/connection-modelgateway-static.bicep' = if (!empty(staticModels)) {
//   name: 'model-gateway-connection-static'
//   params: {
//     aiFoundryName: aiFoundryName
//     connectionName: 'model-gateway-${resourceToken}-static'
//     apiKey: apim.outputs.subscriptionValue
//     isSharedToAll: true
//     gatewayName: 'apim'
//     staticModels: staticModels
//     inferenceAPIVersion: '2025-03-01-preview'
//     targetUrl: apim.outputs.apiUrl
//     deploymentInPath: 'true'
//   }
// }

// module modelGatewayConnectionDynamic '../ai/connection-modelgateway-dynamic.bicep' = {
//   name: 'model-gateway-connection-dynamic'
//   params: {
//     aiFoundryName: aiFoundryName
//     connectionName: 'model-gateway-${resourceToken}-dynamic'
//     apiKey: apim.outputs.subscriptionValue
//     isSharedToAll: true
//     gatewayName: 'apim'
//     targetUrl: apim.outputs.apiUrl
//     listModelsEndpoint: '/deployments'
//     getModelEndpoint: '/deployments/{deploymentName}'
//     deploymentProvider: 'AzureOpenAI'
//     inferenceAPIVersion: '2025-03-01-preview'
//     deploymentInPath: 'true'
//   }
// }

output apimResourceId string = apim.outputs.apimResourceId
output apimName string = apim.outputs.apimName
output apimGatewayUrl string = apim.outputs.apimGatewayUrl
output apimPrincipalId string = apim.outputs.apimPrincipalId
output apimAppInsightsLoggerId string = apim.outputs.apimAppInsightsLoggerId
