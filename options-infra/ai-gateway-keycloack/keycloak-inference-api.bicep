@description('Name of the existing APIM service.')
param apiManagementName string

@description('ID of the APIM Application Insights logger.')
param apimLoggerId string

@description('Application Insights instrumentation key.')
@secure()
param appInsightsInstrumentationKey string

@description('Application Insights resource ID.')
param appInsightsResourceId string

@description('Keycloak client-credentials token endpoint proxied through this API.')
param keycloakTokenUrl string

@description('Keycloak OpenID Connect discovery endpoint proxied through this API.')
param keycloakOpenIdConfigurationUrl string

var apiName = 'inference-api-keycloak'
var apiPath = 'inference-keycloak'
var authPolicyXml = replace(
  replace(
    loadTextContent('keycloak-auth-policy.xml'),
    '{keycloak-token-url}',
    keycloakTokenUrl
  ),
  '{keycloak-openid-configuration-url}',
  keycloakOpenIdConfigurationUrl
)
var policyXml = replace(
  loadTextContent('../modules/apim/policy-per-model.xml'),
  '{JWT_VALIDATION}',
  authPolicyXml
)

// Reuse the canonical per-model policy and the backend pools created by
// common-apim-setup, but keep Keycloak token acquisition and validation on
// this API only.
module inferenceApi '../modules/apim/v2/inference-api.bicep' = {
  name: 'keycloak-inference-api-deployment'
  params: {
    apiManagementName: apiManagementName
    apimLoggerId: apimLoggerId
    policyXml: policyXml
    aiServicesConfig: []
    inferenceAPIType: 'Other'
    inferenceAPIName: apiName
    inferenceAPIPath: apiPath
    inferenceAPIDisplayName: 'Inference API (Keycloak OAuth2)'
    inferenceAPIDescription: 'Dedicated inference API secured by the Keycloak OIDC policy fragment.'
    configureCircuitBreaker: false
    enableModelDiscovery: false
    requireSubscriptionKey: false
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

output apiName string = inferenceApi.outputs.apiName
output apiPath string = inferenceApi.outputs.apiPath
output tokenPath string = '${inferenceApi.outputs.apiPath}/oauth2/token'
output openIdConfigurationPath string = '${inferenceApi.outputs.apiPath}/oauth2/.well-known/openid-configuration'
