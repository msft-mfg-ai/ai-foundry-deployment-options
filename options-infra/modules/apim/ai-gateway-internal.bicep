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
    apimSku: 'Developer'
    virtualNetworkType: 'Internal'
    subnetResourceId: subnetResourceId
    subscriptions: subscriptions
  }
}

module apim_dns 'apim-dns.bicep' = {
  name: 'apim-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apim.outputs.apimPrivateIp
    vnetResourceIds: [vnetResourceId]
    apimName: apim.outputs.apimName
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
output apimPrincipalId string = apim.outputs.apimPrincipalId
