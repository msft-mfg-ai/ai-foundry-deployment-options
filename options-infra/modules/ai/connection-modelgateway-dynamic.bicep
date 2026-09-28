/*
Connections enable your AI applications to access tools and objects managed elsewhere in or outside of Azure.

This example demonstrates how to add a ModelGateway connection with dynamic model discovery.
ModelGateway connections provide a unified interface for various AI model providers.
Uses ApiKey authentication with dynamic model discovery using API endpoints.

Configuration includes:
- deploymentInPath: Controls how deployment names are passed to the gateway in inference api calls
- inferenceAPIVersion: API version for model inference calls
- deploymentAPIVersion: API version for deployment management calls
- modelDiscovery: Dynamic endpoints for model discovery with OpenAI format

Dynamic model discovery endpoints:
- List Models: /v1/models
- Get Model: /v1/models/{deploymentName}
- Provider: OpenAI format responses

IMPORTANT: Make sure you are logged into the subscription where the AI Foundry resource exists before deploying.
The connection will be created in the AI Foundry project, so you need to be in that subscription context.
Use: az account set --subscription <foundry-subscription-id>
*/

param aiFoundryName string
param aiFoundryProjectName string?
param targetUrl string = 'https://your-model-gateway.example.com'
param gatewayName string = 'example-gateway'

// Connection configuration
@allowed(['ApiKey', 'OAuth2', 'ProjectManagedIdentity'])
param authType string = 'ApiKey'
param isSharedToAll bool = true

// Connection naming - can be overridden via parameter
param connectionName string = ''  // Optional: specify custom connection name

// API key for the ModelGateway endpoint (only used when authType=ApiKey).
@secure()
param apiKey string = ''

@description('OAuth2 client ID. Required when authType is OAuth2.')
param clientId string = ''

@secure()
@description('OAuth2 client secret. Required when authType is OAuth2.')
param clientSecret string = ''

@description('OAuth2 token endpoint. Required when authType is OAuth2.')
param tokenUrl string = ''

@description('OAuth2 scopes requested by Foundry. At least one is required when authType is OAuth2.')
param scopes string[] = []

@description('Audience for the bearer token under ProjectManagedIdentity auth.')
param audience string = 'https://cognitiveservices.azure.com'

// for custom apiKey - https://github.com/meerakurup/foundry-samples/blob/063938d46216489200f7582eed8f759e4ddc2410/samples/microsoft/infrastructure-setup/01-connections/model-gateway/connection-modelgateway-custom-auth-config.bicep

// Generate connection name if not provided
var generatedConnectionName = 'modelgateway-${gatewayName}-dynamic'
var finalConnectionName = connectionName != '' ? connectionName : generatedConnectionName

// ModelGateway-specific configuration parameters
@allowed([
  'true'
  'false'
])
param deploymentInPath string = 'false'  // Controls how deployment names are passed to the gateway

param inferenceAPIVersion string = ''  // API version for inference calls
param deploymentAPIVersion string = ''  // API version for deployment management calls

// Model discovery configuration (dynamic endpoints)
param listModelsEndpoint string = '/v1/models'  // Endpoint for listing models
param getModelEndpoint string = '/v1/models/{deploymentName}'  // Endpoint for getting specific model
param deploymentProvider string = 'OpenAI'  // Provider format for response parsing

// Build the modelDiscovery object and serialize it as JSON string
var modelDiscoveryObject = {
  listModelsEndpoint: listModelsEndpoint
  getModelEndpoint: getModelEndpoint
  deploymentProvider: deploymentProvider
}

// Build the metadata object for ModelGateway Dynamic Discovery
// All values must be strings, including serialized JSON objects
var modelGatewayMetadata = {
  deploymentInPath: deploymentInPath
  inferenceAPIVersion: inferenceAPIVersion
  deploymentAPIVersion: deploymentAPIVersion
  modelDiscovery: string(modelDiscoveryObject)  // Serialize as JSON string
}

// Use the common module to create the ModelGateway connection
module modelGatewayConnection 'modelgateway-connection-common.bicep' = {
  name: '${finalConnectionName}-deployment'
  params: {
    aiFoundryName: aiFoundryName
    aiFoundryProjectName: aiFoundryProjectName
    connectionName: finalConnectionName
    targetUrl: targetUrl
    authType: authType
    audience: audience
    isSharedToAll: isSharedToAll
    apiKey: apiKey
    clientId: clientId
    clientSecret: clientSecret
    tokenUrl: tokenUrl
    scopes: scopes
    metadata: modelGatewayMetadata
  }
}

// Output information from the connection
output connectionName string = modelGatewayConnection.outputs.connectionName
output connectionId string = modelGatewayConnection.outputs.connectionId
output targetUrl string = modelGatewayConnection.outputs.targetUrl
output authType string = modelGatewayConnection.outputs.authType
output metadata object = modelGatewayConnection.outputs.metadata
