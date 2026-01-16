/*
Common module for creating APIM connections to Foundry projects.
This module handles the core connection logic and can be reused across different APIM connection samples.
*/
// https://github.com/azure-ai-foundry/foundry-samples/blob/main/infrastructure/infrastructure-setup-bicep/01-connections/apim/connection-apim.bicep

// Project resource parameters
param aiFoundryName string
param aiFoundryProjectName string?
param connectionName string = ''

// APIM resource parameters  
param apimResourceId string
param apimCustomDomainGatewayUrl string?
param apiName string
param apimSubscriptionName string = 'master'

// 1. REQUIRED - Basic APIM Configuration
@allowed(['true', 'false'])
@description('Whether deployment name is in URL path vs query parameter')
param deploymentInPath string = 'true'

@description('API version for inference calls (chat completions, embeddings)')
param inferenceAPIVersion string = ''

// 2. OPTIONAL - Deployment API Version
@description('API version for deployment management (optional)')
param deploymentAPIVersion string = ''

// 3. OPTIONAL - Dynamic Discovery Configuration
@description('Endpoint for listing models (enables dynamic discovery)')
param listModelsEndpoint string = ''

@description('Endpoint for getting model details (enables dynamic discovery)')
param getModelEndpoint string = ''

@description('Provider for model discovery (AzureOpenAI, etc.)')
param deploymentProvider string = ''

// 4. OPTIONAL - Static Model List
@description('Static model list (array of model objects, optional)')
param staticModels ModelType[] = []

@export()
type ModelType = {
  name: string
  properties: {
    model:{
      format: string
      name: string
      version: string
    }
  }
}

// 5. OPTIONAL - Custom Headers
@description('Custom headers (object with string key-value pairs, optional)')
param customHeaders object = {}

// 6. OPTIONAL - Custom Authentication Configuration
@description('Authentication configuration (object for custom auth headers)')
param authConfig object = {}

// Connection configuration
param authType string = 'ApiKey'
param isSharedToAll bool = false

// APIM-specific metadata (passed through from parent template)
// Build metadata using conditional union - includes only non-empty parameters
var metadata = union(
  // Always include basic configuration
  {
    deploymentInPath: deploymentInPath
  },
  // Conditionally include inference API version
  hasInferenceAPIVersion ? {
    inferenceAPIVersion: inferenceAPIVersion
  } : {},
  // Conditionally include deployment API version
  hasDeploymentAPIVersion ? {
    deploymentAPIVersion: deploymentAPIVersion
  } : {},
  // Conditionally include model discovery configuration
  hasModelDiscovery ? { 
    modelDiscovery: string({
      listModelsEndpoint: listModelsEndpoint
      getModelEndpoint: getModelEndpoint
      deploymentProvider: deploymentProvider
    })
  } : {},
  // Conditionally include static models (only if no dynamic discovery)
  hasStaticModels && !hasModelDiscovery ? { 
    models: string(staticModels)
  } : {},
  // Conditionally include custom headers
  hasCustomHeaders ? {
    customHeaders: string(customHeaders)
  } : {},
  // Conditionally include custom auth configuration
  hasAuthConfig ? {
    authConfig: string(authConfig)
  } : {}
)

// Helper variables for conditional logic
var hasDeploymentAPIVersion = deploymentAPIVersion != ''
var hasInferenceAPIVersion = inferenceAPIVersion != ''
var hasModelDiscovery = listModelsEndpoint != '' && getModelEndpoint != '' && deploymentProvider != ''
var hasStaticModels = length(staticModels) > 0
var hasCustomHeaders = !empty(customHeaders)
var hasAuthConfig = !empty(authConfig)

// Validation: Fail deployment if both static models and dynamic discovery are configured
var modelDiscoveryValid = hasModelDiscovery && hasStaticModels
? fail('ERROR: Cannot configure both static models and dynamic discovery. Use either staticModels array OR modelDiscovery parameters, not both.')
: true

// Validation: Fail deployment if neither static models nor dynamic discovery is configured
var configurationValid = !hasModelDiscovery && !hasStaticModels
? fail('ERROR: Must configure either static models (staticModels array) OR dynamic discovery (listModelsEndpoint, getModelEndpoint, deploymentProvider). Cannot have neither.')
: true

output validationStatus bool = modelDiscoveryValid && configurationValid

// Extract APIM information from resource ID
var apimSubscriptionId = split(apimResourceId, '/')[2]
var apimResourceGroupName = split(apimResourceId, '/')[4]
var apimServiceName = split(apimResourceId, '/')[8]

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = if (aiFoundryProjectName != null) {
  name: aiFoundryProjectName!
  parent: aiFoundry
}

// Reference the APIM service (can be in different resource group/subscription)
resource existingApim 'Microsoft.ApiManagement/service@2021-08-01' existing = {
  name: apimServiceName
  scope: resourceGroup(apimSubscriptionId, apimResourceGroupName)
}

// Reference the specific API within APIM
resource apimApi 'Microsoft.ApiManagement/service/apis@2021-08-01' existing = {
  name: apiName
  parent: existingApim
}

// Reference the APIM subscription to get keys (only for ApiKey auth)
resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2021-08-01' existing = {
  name: apimSubscriptionName
  parent: existingApim
}

// Create the connection with ApiKey authentication
resource connectionApiKey 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (authType == 'ApiKey' && aiFoundryProjectName == null) {
  name: connectionName
  parent: aiFoundry
  properties: {
    category: 'ApiManagement'
    target: '${apimCustomDomainGatewayUrl ?? existingApim.properties.gatewayUrl}/${apimApi.properties.path}'
    authType: 'ApiKey'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
    }
    metadata: metadata
  }
}

// Create the connection with ApiKey authentication
resource connectionProjectApiKey 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (authType == 'ApiKey' && aiFoundryProjectName != null) {
  name: connectionName
  parent: aiProject
  properties: {
    category: 'ApiManagement'
    target: '${apimCustomDomainGatewayUrl ?? existingApim.properties.gatewayUrl}/${apimApi.properties.path}'
    authType: 'ApiKey'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
    }
    metadata: metadata
  }
}

// TODO: Future AAD connection (when role assignments are implemented)
// resource connectionAAD 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (authType == 'AAD') {
//   name: connectionName
//   parent: aiProject
//   properties: {
//     category: 'ApiManagement'
//     target: '${existingApim.properties.gatewayUrl}/${apimApi.properties.path}'
//     authType: 'AAD'
//     isSharedToAll: isSharedToAll
//     credentials: {}
//     metadata: metadata
//   }
// }

// Outputs (only from the created connection)
output connectionName string = authType == 'ApiKey' ? connectionApiKey.name : ''
output connectionId string = authType == 'ApiKey' ? connectionApiKey.id : ''
output targetUrl string = '${existingApim.properties.gatewayUrl}/${apimApi.properties.path}'
output authType string = authType
output metadata object = metadata
