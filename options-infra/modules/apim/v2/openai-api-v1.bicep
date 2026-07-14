/**
 * SDK-friendly OpenAI v1 API surface for APIM.
 *
 * Exposes the direct `/openai/v1` route using the OpenAI v1 OpenAPI contract
 * while reusing the caller identity and per-model routing policy.
 */

@description('The name of the API Management instance.')
param apiManagementName string

@description('Id of the Azure Monitor APIM Logger.')
param apimLoggerId string = ''

@description('The resource ID for Application Insights APIM Logger.')
param appInsightsLoggerId string = ''

@description('The instrumentation key for Application Insights.')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights.')
param appInsightsId string = ''

@description('The XML content for the API policy.')
param policyXml string

@description('The name of the OpenAI v1 API in API Management.')
param inferenceAPIName string = 'openai-api-v1'

@description('The description of the OpenAI v1 API in API Management.')
param inferenceAPIDescription string = 'OpenAI API v1 for AI Gateway'

@description('The display name of the OpenAI v1 API in API Management.')
param inferenceAPIDisplayName string = 'OpenAI API v1'

@description('The APIM URL base path for the SDK-friendly OpenAI v1 API.')
param inferenceAPIPath string = 'openai/v1'

@description('Require a valid APIM subscription key on every request. Set to true to enforce subscription key validation.')
param requireSubscriptionKey bool = true

@description('OpenAPI document URL for OpenAI v1 operations. Defaults to the repo-local spec published from options-infra/modules/apim/v2/specs/azure-v1-v1-generated.json.')
param openApiSpecUrl string = 'https://raw.githubusercontent.com/msft-mfg-ai/ai-foundry-config-testing/refs/heads/main/options-infra/modules/apim/v2/specs/azure-v1-v1-generated.json'

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
    format: 'openapi+json-link'
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
    value: openApiSpecUrl
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

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (!empty(apimLoggerId)) {
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
    loggerId: !empty(appInsightsLoggerId) ? appInsightsLoggerId : resourceId(resourceGroup().name, 'Microsoft.ApiManagement/service/loggers', apiManagementName, 'appinsights-logger')
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
