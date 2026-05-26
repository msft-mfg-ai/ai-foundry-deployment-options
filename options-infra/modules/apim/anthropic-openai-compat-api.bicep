/**
 * @module anthropic-openai-compat-api
 * @description Creates an APIM API that accepts OpenAI Chat Completions requests and
 * transparently proxies them to Anthropic's Messages API, translating both the request
 * and response on the fly. Exposed at inference/openai-compat/chat/completions.
 *
 * Callers configure the OpenAI SDK with:
 *   base_url = "https://<apim>.azure-api.net/inference/openai-compat"
 *   api_key  = "<apim-subscription-key>"
 */

param apiManagementName string
param policyXml string

@description('Id of the APIM logger for Azure Monitor diagnostics')
param apimLoggerId string = ''

@description('App Insights instrumentation key for request/response logging')
@secure()
param appInsightsInstrumentationKey string = ''

@description('App Insights resource ID for diagnostics')
param appInsightsId string = ''

var apiName        = 'anthropic-openai-compat-api'
var apiDisplayName = 'Anthropic (OpenAI-compatible)'
var apiDescription = 'OpenAI Chat Completions API that transparently translates requests to Anthropic Messages format and responses back. Use this API with any OpenAI-compatible client pointing to inference/openai-compat.'

var logSettings = {
  body: {
    bytes: 8192
  }
  headers: []
}

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

// Minimal OpenAPI 3.0 spec describing the single operation this API exposes.
var apiSpec = string({
  openapi: '3.0.1'
  info: {
    title: apiDisplayName
    description: apiDescription
    version: '1.0'
  }
  paths: {
    '/chat/completions': {
      post: {
        operationId: 'CreateChatCompletion'
        summary: 'Creates a model response for the given chat conversation (OpenAI format, backed by Anthropic)'
        requestBody: {
          required: true
          content: {
            'application/json': {
              schema: {
                type: 'object'
                required: ['model', 'messages']
                properties: {
                  model: {
                    type: 'string'
                    description: 'Model name, e.g. claude-opus-4-6'
                  }
                  messages: {
                    type: 'array'
                    items: {
                      type: 'object'
                      properties: {
                        role:    { type: 'string', enum: ['system', 'user', 'assistant'] }
                        content: { type: 'string' }
                      }
                    }
                  }
                  max_tokens:  { type: 'integer', description: 'Defaults to 4096 if omitted' }
                  temperature: { type: 'number' }
                  top_p:       { type: 'number' }
                  stream:      { type: 'boolean', description: 'Streaming is not supported in this compat layer; always treated as false' }
                  stop:        { description: 'Mapped to Anthropic stop_sequences' }
                }
              }
            }
          }
        }
        responses: {
          '200': {
            description: 'Chat completion (OpenAI format)'
            content: {
              'application/json': {
                schema: {
                  type: 'object'
                  properties: {
                    id:      { type: 'string' }
                    object:  { type: 'string', enum: ['chat.completion'] }
                    created: { type: 'integer' }
                    model:   { type: 'string' }
                    choices: { type: 'array' }
                    usage:   { type: 'object' }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
})

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimService
  name: apiName
  properties: {
    apiType: 'http'
    displayName: apiDisplayName
    description: apiDescription
    format: 'openapi+json'
    value: apiSpec
    path: 'inference/openai-compat'
    protocols: ['https']
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: true
    type: 'http'
  }
}

// Reuse the shared 'inference' tag so this API is grouped with the other inference APIs.
resource inferenceTag 'Microsoft.ApiManagement/service/tags@2024-06-01-preview' existing = {
  name: 'inference'
  parent: apimService
}

resource apiTag 'Microsoft.ApiManagement/service/apis/tags@2024-06-01-preview' = {
  name: 'inference'
  parent: api
  dependsOn: [inferenceTag]
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: policyXml
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
      response: logSettings
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

output apiId   string = api.id
output apiName string = api.name
output apiPath string = api.properties.path
