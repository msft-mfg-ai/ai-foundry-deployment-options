// Anthropic pass-through inference API — layer-on-top module.
//
// Deploys the legacy Anthropic Claude pass-through inference API onto an
// ALREADY-CREATED APIM instance. This is consumed ONLY by the
// `ai-gateway-anthropic` sample (cross-tenant Foundry-hosted Claude endpoint
// authenticated with a backend API key rather than managed identity).
//
// It was extracted out of the generic `apim.bicep` wrapper so that
// Anthropic-only settings (anthropic-policy.xml, the backend API key, the
// Anthropic backend pool) do not pollute the shared module used by every other
// AI Gateway option.
//
// Precondition: the `caller-identity` policy fragment must already exist on the
// target APIM (created by `apim.bicep` via caller-identity-fragment.bicep).
// anthropic-policy.xml references it with <include-fragment fragment-id="caller-identity" />.

import { aiServiceConfigType } from 'v2/inference-api.bicep'

@description('Name of the existing API Management instance to layer the Anthropic API onto.')
param apiManagementName string

@description('Id of the APIM Logger used for diagnostics.')
param apimLoggerId string = ''

@description('Configuration array for Anthropic AI Services (Foundry-hosted Claude models).')
param anthropicServicesConfig aiServiceConfigType[]

@description('API key for the Anthropic Foundry endpoint. Use for cross-tenant endpoints where managed identity is not available.')
@secure()
param anthropicApiKey string = ''

@description('The instrumentation key for Application Insights.')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights.')
param appInsightsId string = ''

var updatedAnthropicPolicyXml = replace(
  replace(
    replace(
      loadTextContent('anthropic-policy.xml'),
      '{retry-count}',
      string(max(length(anthropicServicesConfig) - 1, 1))
    ),
    'SUBSCRIPTION_ID',
    subscription().subscriptionId
  ),
  'TENANT_ID',
  subscription().tenantId
)

// Anthropic API — Foundry-hosted Claude models proxied through APIM.
// Uses PassThrough spec + JWT validation policy. Backend Anthropic api-key is
// supplied by APIM (via the `credentials` on the backend resource), so callers
// don't send any key.
module anthropic_api 'v2/inference-api.bicep' = {
  name: 'anthropic-api-deployment'
  params: {
    policyXml: updatedAnthropicPolicyXml
    apiManagementName: apiManagementName
    apimLoggerId: apimLoggerId
    aiServicesConfig: anthropicServicesConfig
    inferenceAPIType: 'Anthropic'
    inferenceAPIPath: 'inference'
    inferenceAPIDescription: 'Anthropic Claude API for AI Gateway'
    inferenceAPIDisplayName: 'Anthropic API'
    inferenceAPIName: 'anthropic-api'
    configureCircuitBreaker: true
    enableModelDiscovery: false
    // anthropic-policy.xml validates the caller's JWT and requires
    // xms_mirid to belong to this subscription, so APIM subscription auth
    // is redundant.
    requireSubscriptionKey: false
    backendApiKey: anthropicApiKey
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
  }
}

output anthropicApiName string = anthropic_api.outputs.apiName
output anthropicApiPath string = anthropic_api.outputs.apiPath
