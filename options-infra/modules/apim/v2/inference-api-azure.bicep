/**
 * Spec-backed Azure OpenAI inference API for APIM.
 *
 * This API is intentionally separate from the passthrough catch-all inference API:
 * it imports the Azure OpenAI OpenAPI contract so the APIM portal Test console
 * shows typed operations, while reusing the same per-model routing policy.
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

@description('The XML content for the API policy.')
param policyXml string

@description('The name of the Azure OpenAI spec-backed API in API Management.')
param inferenceAPIName string = 'inference-api-azure'

@description('The description of the Azure OpenAI spec-backed API in API Management.')
param inferenceAPIDescription string = 'AzureOpenAI-spec inference API — same per-model routing as the passthrough, with portal test console and per-operation definitions.'

@description('The display name of the Azure OpenAI spec-backed API in API Management.')
param inferenceAPIDisplayName string = 'Inference API (Azure OpenAI spec)'

@description('The APIM URL base path for the Azure OpenAI spec-backed API. The module appends `/openai` unless the path already ends with `/openai`, matching the existing AzureOpenAI inference API contract.')
param inferenceAPIPath string = 'azure'

@description('Require a valid APIM subscription key on every request. Set to true to enforce subscription key validation.')
param requireSubscriptionKey bool = true

@description('OpenAPI document URL for Azure OpenAI operations. Defaults to the repo-local spec published from options-infra/modules/apim/v2/specs/AIFoundryOpenAI.json.')
param openApiSpecUrl string = 'https://raw.githubusercontent.com/msft-mfg-ai/ai-foundry-config-testing/refs/heads/main/options-infra/modules/apim/v2/specs/AIFoundryOpenAI.json'

import { requestLogSettings, responseLogSettings } from '../log-settings.bicep'

var logSettings = requestLogSettings
var apiPath = endsWith(inferenceAPIPath, '/openai') ? inferenceAPIPath : '${inferenceAPIPath}/openai'

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
    path: apiPath
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

resource inferenceTag 'Microsoft.ApiManagement/service/tags@2024-06-01-preview' = {
  name: 'inference'
  parent: apimService
  properties: {
    displayName: 'inference'
  }
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
