/**
 * Mock inference API for APIM.
 *
 * Exposes a `/inference-mock` API that answers chat completions (both streaming
 * and non-streaming) with a canned "I'm an LLM mock" response, mimicking the
 * headers and JSON shape Azure AI Foundry / Azure OpenAI return. No backend is
 * called — the policy uses `<return-response>` so this API works even without
 * any Foundry instance behind APIM.
 *
 * Operations:
 *   POST /openai/deployments/{deployment}/chat/completions  (Azure OpenAI shape)
 *   POST /chat/completions                                  (OpenAI v1 shape)
 *
 * Streaming: if the request body contains `"stream": true` the policy replies
 * with `Content-Type: text/event-stream` and multiple `data: {...}` SSE chunks
 * ending in `data: [DONE]`. SSE is line-based so clients using
 * `stream=True` parse the payload correctly even though APIM emits it in a
 * single response body.
 */

@description('The name of the API Management instance.')
param apiManagementName string

@description('Id of the Azure Monitor APIM Logger.')
param apimLoggerId string = ''

@description('The instrumentation key for Application Insights.')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights.')
param appInsightsId string = ''

@description('The name of the mock inference API in API Management.')
param inferenceAPIName string = 'inference-mock'

@description('The description of the mock inference API in API Management.')
param inferenceAPIDescription string = 'Mock inference API — returns a canned "I\'m an LLM mock" chat completion response for streaming and non-streaming requests. No backend is called.'

@description('The display name of the mock inference API in API Management.')
param inferenceAPIDisplayName string = 'Inference API (Mock)'

@description('The APIM URL base path for the mock inference API.')
param inferenceAPIPath string = 'inference-mock'

@description('Require a valid APIM subscription key on every request.')
param requireSubscriptionKey bool = true

import { requestLogSettings, responseLogSettings } from '../log-settings.bicep'

var logSettings = requestLogSettings

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: inferenceAPIName
  parent: apimService
  properties: {
    apiType: 'http'
    description: inferenceAPIDescription
    displayName: inferenceAPIDisplayName
    path: inferenceAPIPath
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: requireSubscriptionKey
    type: 'http'
  }
}

resource aiGatewayTag 'Microsoft.ApiManagement/service/tags@2024-06-01-preview' = {
  name: 'ai-gateway'
  parent: apimService
  properties: {
    displayName: 'AI Gateway'
  }
}

resource aiGatewayApiTag 'Microsoft.ApiManagement/service/apis/tags@2024-06-01-preview' = {
  name: 'ai-gateway'
  parent: api
  dependsOn: [aiGatewayTag]
}

var mockPolicyXml = loadTextContent('policy-mock-chat.xml')

// API-level policy: no-op inbound; the per-operation policy owns return-response.
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Azure OpenAI–style operation:  POST /openai/deployments/{deployment}/chat/completions
resource azureChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'azure-chat-completions'
  parent: api
  properties: {
    displayName: 'Azure OpenAI chat completions (mock)'
    method: 'POST'
    urlTemplate: '/openai/deployments/{deployment}/chat/completions'
    description: 'Mock Azure OpenAI chat completions endpoint. Returns "I\'m an LLM mock" (streaming or non-streaming).'
    templateParameters: [
      {
        name: 'deployment'
        required: true
        type: 'string'
        description: 'Deployment / model name (echoed back in the response).'
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
          {
            contentType: 'text/event-stream'
          }
        ]
      }
    ]
  }
}

resource azureChatPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: azureChatOperation
  properties: {
    format: 'rawxml'
    value: mockPolicyXml
  }
}

// OpenAI v1–style operation:  POST /chat/completions
resource openaiChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'openai-chat-completions'
  parent: api
  properties: {
    displayName: 'OpenAI chat completions (mock)'
    method: 'POST'
    urlTemplate: '/chat/completions'
    description: 'Mock OpenAI v1 chat completions endpoint. Returns "I\'m an LLM mock" (streaming or non-streaming).'
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [
          {
            contentType: 'application/json'
          }
          {
            contentType: 'text/event-stream'
          }
        ]
      }
    ]
  }
}

resource openaiChatPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: openaiChatOperation
  properties: {
    format: 'rawxml'
    value: mockPolicyXml
  }
}

// Foundry BYOM–style operation:  POST /deployments/{deployment}/chat/completions
// Foundry's BYOM data-proxy calls the target URL as `{apim-base}/{apiPath}/deployments/{model}/chat/completions`
// — same shape as Azure OpenAI but WITHOUT the `/openai/` segment prefix.
// Present so the mock is a drop-in for BYOM connections targeting this API.
resource byomChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'byom-chat-completions'
  parent: api
  properties: {
    displayName: 'BYOM chat completions (mock)'
    method: 'POST'
    urlTemplate: '/deployments/{deployment}/chat/completions'
    description: 'Mock BYOM chat completions endpoint (Foundry data-proxy shape).'
    templateParameters: [
      {
        name: 'deployment'
        required: true
        type: 'string'
        description: 'Deployment / model name (echoed back in the response).'
      }
    ]
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [
          { contentType: 'application/json' }
          { contentType: 'text/event-stream' }
        ]
      }
    ]
  }
}

resource byomChatPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: byomChatOperation
  properties: {
    format: 'rawxml'
    value: mockPolicyXml
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (length(apimLoggerId) > 0) {
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
      response: responseLogSettings
    }
    backend: {
      request: logSettings
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

output apiId string = api.id
output apiName string = api.name
output apiPath string = api.properties.path
