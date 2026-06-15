// ============================================================================
// -- Foundry connection(s) — static models drive the portal model picker
// ============================================================================
import { ModelType } from '../ai/connection-apim-gateway.bicep'

param aiFoundryName string
param aiFoundryProjectNames string[] = []
param resourceToken string
@allowed(['ApiKey', 'ProjectManagedIdentity'])
param gatewayAuthenticationType string = 'ProjectManagedIdentity'
param staticModels ModelType[] = []

param apimResourceId string
param inferenceApiName string
param apimSubscriptionNames string[] = []

/// Variables
var connection_per_project = !empty(aiFoundryProjectNames)

var openAIStaticModels = filter(staticModels, m => toLower(m.properties.model.format) != 'anthropic')
var anthropicStaticModels = filter(staticModels, m => toLower(m.properties.model.format) == 'anthropic')

module aiGatewayConnectionDynamic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project) {
  name: 'apim-connection-openai-dynamic'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-openai-dynamic'
    apimResourceId: apimResourceId
    apiName: inferenceApiName
    apimSubscriptionName: first(apimSubscriptionNames)
    isSharedToAll: true
    listModelsEndpoint: '/deployments'
    getModelEndpoint: '/deployments/{deploymentName}'
    deploymentProvider: 'AzureOpenAI'
    inferenceAPIVersion: '2025-03-01-preview'
    authType: gatewayAuthenticationType
  }
}

// Static-models connection: the Foundry portal only displays `staticModels` when
// the connection uses `ProjectManagedIdentity` auth AND has non-empty
// `metadata.customHeaders`. The connection-apim-gateway.bicep module enforces
// both defaults (PMI by default; api-key auto-injected as customHeaders when
// apimSubscriptionName is provided). Override `gatewayAuthenticationType` only
// if you accept that the portal will show a misleading global-catalog count.
module aiGatewayConnectionStatic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project && !empty(staticModels)) {
  name: 'apim-connection-openai-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-openai-static'
    apimResourceId: apimResourceId
    apiName: inferenceApiName
    apimSubscriptionName: first(apimSubscriptionNames)
    isSharedToAll: true
    staticModels: openAIStaticModels
    inferenceAPIVersion: '2025-03-01-preview'
    authType: gatewayAuthenticationType
  }
}

module aiGatewayProjectConnectionStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(staticModels)) {
    name: 'apim-connection-openai-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-openai-s-for-${projectName}'
      apimResourceId: apimResourceId
      apiName: inferenceApiName
      apimSubscriptionName: first(filter(apimSubscriptionNames, (sub) => contains(sub, projectName)))
      isSharedToAll: false
      staticModels: openAIStaticModels
      inferenceAPIVersion: '2025-03-01-preview'
      authType: gatewayAuthenticationType
    }
  }
]

module aiGatewayProjectConnectionDynamic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project) {
    name: 'apim-connection-openai-dynamic-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-openai-d-for-${projectName}'
      apimResourceId: apimResourceId
      apiName: inferenceApiName
      apimSubscriptionName: first(filter(apimSubscriptionNames, (sub) => contains(sub, projectName)))
      isSharedToAll: false
      listModelsEndpoint: '/deployments'
      getModelEndpoint: '/deployments/{deploymentName}'
      deploymentProvider: 'AzureOpenAI'
      inferenceAPIVersion: '2025-03-01-preview'
      authType: gatewayAuthenticationType
    }
  }
]

/// Anthropic connections (deploymentInPath=false because Claude API does not use deployment-shaped URLs)

module aiGatewayConnectionAnthropicStatic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project && !empty(anthropicStaticModels)) {
  name: 'apim-connection-anthropic-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-anthropic-static'
    apimResourceId: apimResourceId
    apiName: inferenceApiName
    apimSubscriptionName: first(apimSubscriptionNames)
    isSharedToAll: true
    staticModels: anthropicStaticModels
    inferenceAPIVersion: '2025-03-01-preview'
    deploymentInPath: 'false'
    authType: gatewayAuthenticationType
  }
}

module aiGatewayConnectionAnthropicDynamic '../ai/connection-apim-gateway.bicep' = if (!connection_per_project) {
  name: 'apim-connection-anthropic-dynamic'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-anthropic-dynamic'
    apimResourceId: apimResourceId
    apiName: inferenceApiName
    apimSubscriptionName: first(apimSubscriptionNames)
    isSharedToAll: true
    inferenceAPIVersion: '2025-03-01-preview'
    deploymentInPath: 'false'
    authType: gatewayAuthenticationType
    listModelsEndpoint: '/deployments'
    getModelEndpoint: '/deployments/{deploymentName}'
    deploymentProvider: 'AzureOpenAI'
  }
}

module aiGatewayProjectConnectionAnthropicStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project && !empty(anthropicStaticModels)) {
    name: 'apim-connection-anthropic-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-anthropic-s-for-${projectName}'
      apimResourceId: apimResourceId
      apiName: inferenceApiName
      apimSubscriptionName: first(filter(apimSubscriptionNames, (sub) => contains(sub, projectName)))
      isSharedToAll: false
      staticModels: anthropicStaticModels
      inferenceAPIVersion: '2025-03-01-preview'
      deploymentInPath: 'false'
      authType: gatewayAuthenticationType
    }
  }
]

module aiGatewayProjectConnectionAnthropicDynamic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connection_per_project) {
    name: 'apim-connection-anthropic-dynamic-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-anthropic-d-for-${projectName}'
      apimResourceId: apimResourceId
      apiName: inferenceApiName
      apimSubscriptionName: first(filter(apimSubscriptionNames, (sub) => contains(sub, projectName)))
      isSharedToAll: false
      listModelsEndpoint: '/deployments'
      getModelEndpoint: '/deployments/{deploymentName}'
      deploymentProvider: 'AzureOpenAI'
      inferenceAPIVersion: '2025-03-01-preview'
      deploymentInPath: 'false'
      authType: gatewayAuthenticationType
    }
  }
]
