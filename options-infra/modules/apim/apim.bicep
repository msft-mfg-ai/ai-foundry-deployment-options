import { aiServiceConfigType } from 'v2/inference-api.bicep'
import { subscriptionType, hostnameConfigurationType } from 'v2/apim.bicep'

param location string = resourceGroup().location
param tags object = {}
param logAnalyticsWorkspaceId string
param appInsightsInstrumentationKey string = ''
param appInsightsId string = ''
param inferenceAPIType string = 'AzureOpenAI'
param inferenceAPIPath string = 'inference' // Path to the inference API in the APIM service

@description('Configuration array for AI Services')
param aiServicesConfig aiServiceConfigType[] = []

@description('The suffix to append to the API Management instance name. Defaults to a unique string based on subscription and resource group IDs.')
param resourceSuffix string = uniqueString(subscription().id, resourceGroup().id)

@description('The name of the subscriptions to be created in API Management for the AI Gateway')
param subscriptions subscriptionType[] = []

@allowed([
  'External'
  'Internal'
])
param virtualNetworkType string?
param subnetResourceId string?
@description('The pricing tier of this API Management service')
@allowed([
  'Consumption'
  'Developer'
  'Basic'
  'Basicv2'
  'Standard'
  'Standardv2'
  'Premium'
  'Premiumv2'
])
param apimSku string = 'Basicv2'
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
@description('The user-assigned managed identity ID to be used with API Management')
param apimUserAssignedManagedIdentityResourceId string?
@description('Custom domain hostname configurations for the API Management service')
param hostnameConfigurations hostnameConfigurationType[] = []
@description('The type of managed identity to by used with API Management')
@allowed([
  'SystemAssigned'
  'UserAssigned'
  'SystemAssigned, UserAssigned'
])
param apimManagedIdentityType string = apimUserAssignedManagedIdentityResourceId != null ? 'UserAssigned' : 'SystemAssigned'

module apim 'v2/apim.bicep' = {
  name: 'apim-v2'
  params: {
    location: location
    tags: tags
    apimSubscriptionsConfig: subscriptions
    lawId: logAnalyticsWorkspaceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
    resourceSuffix: resourceSuffix
    apimSku: apimSku
    virtualNetworkType: virtualNetworkType
    subnetResourceId: subnetResourceId
    publicNetworkAccess: publicNetworkAccess
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    apimManagedIdentityType: apimManagedIdentityType
    hostnameConfigurations: hostnameConfigurations
  }
}

var updatedInferencePolicyXml = replace(
  loadTextContent('policy.xml'),
  '{retry-count}',
  string(max(length(aiServicesConfig) - 1, 1)) // Ensure at least 1 retry
) // Try all backends

module inference_api 'v2/inference-api.bicep' = {
  name: 'inference-api-deployment'
  params: {
    policyXml: updatedInferencePolicyXml
    apiManagementName: apim.outputs.name
    apimLoggerId: apim.outputs.loggerId
    aiServicesConfig: aiServicesConfig
    inferenceAPIType: inferenceAPIType
    inferenceAPIPath: inferenceAPIPath
    configureCircuitBreaker: true
    resourceSuffix: resourceSuffix
    enableModelDiscovery: true
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
  }
}

// OpenAI v1 API has more than 100 Operations and requires Premium or Standardv2 SKU
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits?toc=%2Fazure%2Fapi-management%2Ftoc.json&bc=%2Fazure%2Fapi-management%2Fbreadcrumb%2Ftoc.json#limits---api-management-v2-tiers
module openAiv2Api 'v2/inference-api.bicep' = if (apimSku == 'Premium' || apimSku == 'Standardv2') {
  name: 'openai-v2-api-deployment'
  params: {
    policyXml: updatedInferencePolicyXml
    apiManagementName: apim.outputs.name
    apimLoggerId: apim.outputs.loggerId
    aiServicesConfig: aiServicesConfig
    inferenceAPIType: 'OpenAI'
    inferenceAPIPath: 'openai-v1'
    inferenceAPIDescription: 'OpenAI API v1 for AI Gateway'
    inferenceAPIDisplayName: 'OpenAI API v1'
    inferenceAPIName: 'openai-api-v1'
    configureCircuitBreaker: true
    resourceSuffix: resourceSuffix
    enableModelDiscovery: true
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsId
  }
}

output apimResourceId string = apim.outputs.id
output apimName string = apim.outputs.name
output inferenceApiId string = inference_api.outputs.apiId
output inferenceApiName string = inference_api.outputs.apiName
output subscriptions array = apim.outputs.apimSubscriptions
output apimPrincipalId string = apim.outputs.principalId
output apimAppInsightsLoggerId string = apim.outputs.appInsightsLoggerId
output apimPrivateIp string = apim.outputs.apimPrivateIp
output apimPublicIp string = apim.outputs.apimPublicIp
output apimGatewayUrl string = apim.outputs.gatewayUrl
output apiUrl string = '${apim.outputs.gatewayUrl}/${inference_api.outputs.apiPath}'
