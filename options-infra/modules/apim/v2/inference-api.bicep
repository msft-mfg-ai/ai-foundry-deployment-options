/**
 * @module 
 * @description This module defines the API resources using Bicep.
 * It includes configurations for creating and managing APIs, products, and policies.
 * This is version 2 (v2) of the APIM Bicep module.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The suffix to append to the API Management instance name. Defaults to a unique string based on subscription and resource group IDs.')
param resourceSuffix string = uniqueString(subscription().id, resourceGroup().id)

@description('The name of the API Management instance. Defaults to "apim-<resourceSuffix>".')
param apiManagementName string = 'apim-${resourceSuffix}'

@description('Id of the APIM Logger')
param apimLoggerId string = ''

@description('The instrumentation key for Application Insights')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights')
param appInsightsId string = ''

@description('The XML content for the API policy')
param policyXml string

@description('Configuration array for AI Services')
param aiServicesConfig aiServiceConfigType[] = []

@description('The name of the Inference API in API Management.')
param inferenceAPIName string = 'inference-api'

@description('The description of the Inference API in API Management.')
param inferenceAPIDescription string = 'Inferencing API'

@description('The display name of the Inference API in API Management. .')
param inferenceAPIDisplayName string = 'Inference API'

@description('The name of the Inference backend pool.')
param inferenceBackendPoolName string = 'inference-backend-pool-${inferenceAPIType}'

@description('The inference API type')
@allowed([
  'AzureOpenAI'
  'AzureAI'
  'OpenAI'
  'Other'
])
param inferenceAPIType string = 'AzureOpenAI'

@description('The path to the inference API in the APIM service')
param inferenceAPIPath string = 'inference' // Path to the inference API in the APIM service

@description('Whether to configure the circuit breaker for the inference backend')
param configureCircuitBreaker bool = false

@description('Enable dynamic model discovery via ARM API. When true, adds /deployments operations for Foundry Agents.')
param enableModelDiscovery bool = false

// ------------------
//    TYPE DEFINITIONS
// ------------------
@export()
type aiServiceConfigType = {
  @description('The name of the AI service configuration.')
  name: string
  @description('Resource ID of the AI service.')
  resourceId: string
  @description('The location of the AI service.')
  location: string
  @description('The endpoint of the AI service.')
  endpoint: string
  @description('The priority of the AI service in the backend pool.')
  priority: int?
  @description('The weight of the AI service in the backend pool.')
  weight: int?
}

// ------------------
//    VARIABLES
// ------------------

var logSettings = {
  headers: [ 'Content-type', 'User-agent', 'x-ms-region', 'x-ratelimit-remaining-tokens' , 'x-ratelimit-remaining-requests', 'x-aml-data-proxy-url', 'x-aml-vnet-identifier', 'x-aml-static-ingress-ip' ]
  body: { bytes: 8192 }
}

var updatedPolicyXml = replace(policyXml, '{backend-id}', (length(aiServicesConfig) > 1) ? inferenceBackendPoolName : '${aiServicesConfig[0].name}-${inferenceAPIType}-backend')

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

var endpointPaths = {
  AzureOpenAI: 'openai'
  AzureAI: 'models'
  OpenAI: ''
}
var endpointPath = endpointPaths[inferenceAPIType]

// var apiDefinitions = {
//   AzureOpenAI: string(loadJsonContent('./specs/AIFoundryOpenAI.json'))
//   AzureAI: string(loadJsonContent('./specs/AIFoundryOpenAI.json'))
//   OpenAI: 'https://raw.githubusercontent.com/msft-mfg-ai/ai-foundry-config-testing/refs/heads/ai-gateway/options-infra/modules/apim/v2/specs/azure-v1-v1-generated.json'
//   Other: string(loadJsonContent('./specs/PassThrough.json'))
// }
var apiFormats = {
  AzureOpenAI: 'openapi+json'
  AzureAI: 'openapi+json'
  OpenAI: 'openapi+json-link'
  Other: 'openapi+json'
}

var apiDefinition = inferenceAPIType == 'AzureOpenAI' ? string(loadJsonContent('./specs/AIFoundryOpenAI.json'))
  : inferenceAPIType == 'AzureAI' ? string(loadJsonContent('./specs/AIFoundryOpenAI.json'))
  : inferenceAPIType == 'Other' ? string(loadJsonContent('./specs/PassThrough.json'))
  : 'https://raw.githubusercontent.com/msft-mfg-ai/ai-foundry-config-testing/refs/heads/ai-gateway/options-infra/modules/apim/v2/specs/azure-v1-v1-generated.json'
var apiFormat = apiFormats[inferenceAPIType]

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: inferenceAPIName
  parent: apimService
  properties: {
    apiType: 'http'
    description: inferenceAPIDescription
    displayName: inferenceAPIDisplayName
    format: apiFormat
    path: '${inferenceAPIPath}/${endpointPath}'
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: true
    type: 'http'
    value: apiDefinition
  }
}
// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis/policies
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: updatedPolicyXml
  }
}

// ------------------
// MODEL DISCOVERY OPERATIONS (for Foundry Agents)
// https://github.com/azure-ai-foundry/foundry-samples/blob/main/infrastructure/infrastructure-setup-bicep/01-connections/apim/apim-setup-guide-for-agents.md
// ------------------


var listDeploymentsPolicyXml = replace(loadTextContent('deploymentsPolicy.xml'), 'FOUNDRY_ID', first(aiServicesConfig).resourceId)
var getDeploymentPolicyXml = replace(loadTextContent('deploymentPolicy.xml'), 'FOUNDRY_ID', first(aiServicesConfig).resourceId)

// List Deployments Operation - Returns all available models/deployments
resource listDeploymentsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = if (enableModelDiscovery) {
  name: 'list-deployments'
  parent: api
  properties: {
    displayName: 'List Deployments'
    method: 'GET'
    urlTemplate: '/deployments'
    description: 'Lists all available model deployments for Foundry Agents dynamic discovery'
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Policy for List Deployments - routes to Azure Resource Manager API
resource listDeploymentsPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = if (enableModelDiscovery) {
  name: 'policy'
  parent: listDeploymentsOperation
  properties: {
    format: 'rawxml'
    value: listDeploymentsPolicyXml
  }
}

// Get Deployment By Name Operation - Returns details for a specific model/deployment
resource getDeploymentOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = if (enableModelDiscovery) {
  name: 'get-deployment-by-name'
  parent: api
  properties: {
    displayName: 'Get Deployment By Name'
    method: 'GET'
    urlTemplate: '/deployments/{deploymentName}'
    description: 'Retrieves details for a specific model deployment for Foundry Agents'
    templateParameters: [
      {
        name: 'deploymentName'
        required: true
        type: 'string'
        description: 'The name of the deployment to retrieve'
      }
    ]
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Policy for Get Deployment - routes to Azure Resource Manager API
resource getDeploymentPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = if (enableModelDiscovery) {
  name: 'policy'
  parent: getDeploymentOperation
  properties: {
    format: 'rawxml'
    value: getDeploymentPolicyXml
  }
}

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/backends
resource inferenceBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' =  [for (config, i) in aiServicesConfig: if(length(aiServicesConfig) > 0) {
  name: '${config.name}-${inferenceAPIType}-backend'
  parent: apimService
  properties: {
    description: 'Inference backend for ${config.name} API Type: ${inferenceAPIType}'
    url: '${config.endpoint}${endpointPath}'
    protocol: 'http'
    circuitBreaker: (configureCircuitBreaker) ? {
      rules: [
      {
        failureCondition: {
        count: 1
        errorReasons: [
          'Server errors'
        ]
        interval: 'PT1M'
        statusCodeRanges: [
          {
          min: 429
          max: 429
          }
        ]
        }
        name: 'InferenceBreakerRule'
        tripDuration: 'PT1M'
        acceptRetryAfter: true
      }
      ]
    }: null
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
          resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}]

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/backends
resource backendPoolOpenAI 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = if(length(aiServicesConfig) > 1) {
  name: inferenceBackendPoolName
  parent: apimService
  // BCP035: protocol and url are not needed in the Pool type. This is an incorrect error.
  #disable-next-line BCP035
  properties: {
    description: 'Load balancer for multiple inference endpoints'
    type: 'Pool'
    pool: {
      services: [for (config, i) in aiServicesConfig: {
        id: '/backends/${inferenceBackend[i].name}'
        priority: config.?priority
        weight: config.?weight
      }]
    }
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if(length(apimLoggerId) > 0) {
  parent: api
  name: 'azuremonitor'
  properties: {
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    logClientIp: true
    loggerId: apimLoggerId
    sampling: {
      samplingType: 'fixed'
      percentage: json('100')
    }
    frontend: {
      request: logSettings
      response: {
        headers: []
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: []
        body: {
          bytes: 0
        }
      }
      response: logSettings
    }
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
      responses: {
        messages: 'all'
        maxSizeInBytes: 262144
      }
    }
  }
} 

resource apiDiagnosticsAppInsights 'Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  name: 'applicationinsights'
  parent: api
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: resourceId(resourceGroup().name, 'Microsoft.ApiManagement/service/loggers', apiManagementName, 'appinsights-logger')
    metrics: true
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: logSettings
      response: logSettings
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}

// ------------------
//    OUTPUTS
// ------------------

output apiId string = api.id
output apiName string = api.name
output apiPath string = api.properties.path
