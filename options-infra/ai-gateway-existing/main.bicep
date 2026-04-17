// ============================================================================
// Foundry + Project with Existing APIM (Self-Contained)
// ============================================================================
// Deploys:
//   1. Foundry account (AIServices) with optional agent subnet
//   2. A single project with connections to:
//      - Existing APIM (static model connection)
//      - Existing or new: App Insights, Cosmos DB, Storage, AI Search
//   3. Account capability host for Agent Service
//
// All modules are local — no references outside ./modules/.
// ============================================================================
targetScope = 'resourceGroup'

// -- Core Parameters ----------------------------------------------------------

param location string = resourceGroup().location

@description('Resource ID of the agent subnet (delegated to Microsoft.App/environments). Leave empty for no VNet injection.')
param agentSubnetResourceId string = ''

// -- Existing APIM Parameters -------------------------------------------------

@description('Full resource ID of the existing APIM service')
param apimResourceId string

@description('Name of the inference API within APIM (e.g., "inference-api")')
param apimApiName string = 'inference-api'

@description('APIM subscription name for API key auth. Leave empty for ProjectManagedIdentity auth.')
param apimSubscriptionName string = ''

@description('Custom APIM gateway URL (e.g., for custom domain). Leave empty to use default gateway URL.')
param apimCustomDomainGatewayUrl string = ''

@allowed(['ApiKey', 'ProjectManagedIdentity'])
@description('Auth type for the APIM connection. ApiKey requires apimSubscriptionName.')
param apimAuthType string = 'ProjectManagedIdentity'

@description('API version for inference calls')
param inferenceAPIVersion string = '2025-03-01-preview'

// -- Static Models ------------------------------------------------------------

@description('Static model definitions for Foundry model discovery')
param staticModels array = [
  {
    name: 'gpt-4.1-mini'
    properties: {
      model: { name: 'gpt-4.1-mini', version: '2025-01-01-preview', format: 'OpenAI' }
    }
  }
  {
    name: 'gpt-4o'
    properties: {
      model: { name: 'gpt-4o', version: '2025-01-01-preview', format: 'OpenAI' }
    }
  }
]

// -- Existing Dependencies (optional — created when empty) --------------------

@description('Existing App Insights resource ID. Created if empty.')
param existingAppInsightsResourceId string = ''

@description('Existing Cosmos DB resource ID. Created if empty.')
param existingCosmosDBResourceId string = ''

@description('Existing Storage Account resource ID. Created if empty.')
param existingStorageAccountResourceId string = ''

@description('Existing AI Search resource ID. Created if empty.')
param existingAiSearchResourceId string = ''

// -- Variables ----------------------------------------------------------------

var tags = {
  'created-by': 'ai-gateway-existing'
  'hidden-title': 'Foundry + Project with Existing APIM'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var foundryName = 'ai-foundry-${resourceToken}'
var projectName = 'ai-project-${resourceToken}'

// Parse APIM resource ID
var apimParts = split(apimResourceId, '/')
var apimServiceName = apimParts[8]
var apimSubscriptionId = apimParts[2]
var apimResourceGroupName = apimParts[4]

// -- Validation ---------------------------------------------------------------
var _ = apimAuthType == 'ApiKey' && empty(apimSubscriptionName)
  ? fail('ApiKey auth requires apimSubscriptionName to be set.')
  : true

// Compute resource group scopes for role assignments from params (must be deploy-time constants)
var cosmosParts = split(existingCosmosDBResourceId, '/')
var cosmosSubId = !empty(existingCosmosDBResourceId) ? cosmosParts[2] : subscription().subscriptionId
var cosmosRgName = !empty(existingCosmosDBResourceId) ? cosmosParts[4] : resourceGroup().name

var storageParts = split(existingStorageAccountResourceId, '/')
var storageSubId = !empty(existingStorageAccountResourceId) ? storageParts[2] : subscription().subscriptionId
var storageRgName = !empty(existingStorageAccountResourceId) ? storageParts[4] : resourceGroup().name

var searchParts = split(existingAiSearchResourceId, '/')
var searchSubId = !empty(existingAiSearchResourceId) ? searchParts[2] : subscription().subscriptionId
var searchRgName = !empty(existingAiSearchResourceId) ? searchParts[4] : resourceGroup().name

// ============================================================================
// -- Identity
// ============================================================================
module foundry_identity './modules/identity.bicep' = {
  name: 'foundry-identity-${resourceToken}'
  params: {
    identityName: 'id-${foundryName}'
    location: location
    tags: tags
  }
}

// ============================================================================
// -- Foundry Account
// ============================================================================
module foundry './modules/ai-foundry.bicep' = {
  name: 'foundry-${resourceToken}'
  params: {
    name: foundryName
    location: location
    tags: tags
    agentSubnetResourceId: agentSubnetResourceId
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    disableLocalAuth: false
  }
}

// ============================================================================
// -- Log Analytics + App Insights
// ============================================================================
module logAnalytics './modules/loganalytics.bicep' = {
  name: 'log-analytics-${resourceToken}'
  params: {
    newLogAnalyticsName: 'law-${resourceToken}'
    newApplicationInsightsName: 'appi-${resourceToken}'
    existingApplicationInsightsResourceId: existingAppInsightsResourceId
    location: location
    tags: tags
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
  }
}

// ============================================================================
// -- Dependent Resources (Cosmos DB, Storage, AI Search)
// ============================================================================
module dependencies './modules/dependent-resources.bicep' = {
  name: 'dependent-resources-${resourceToken}'
  params: {
    location: location
    tags: tags
    cosmosDBName: 'cosmos-${resourceToken}'
    azureStorageName: take('st${resourceToken}', 24)
    aiSearchName: 'search-${resourceToken}'
    existingCosmosDBResourceId: existingCosmosDBResourceId
    existingStorageAccountResourceId: existingStorageAccountResourceId
    existingAiSearchResourceId: existingAiSearchResourceId
  }
}

// ============================================================================
// -- Project (with connections + capability host)
// ============================================================================
module project './modules/ai-project.bicep' = {
  name: 'project-${resourceToken}'
  params: {
    foundry_name: foundry.outputs.FOUNDRY_NAME
    project_name: projectName
    display_name: 'AI Project'
    project_description: 'AI Project with existing APIM gateway connection'
    location: location
    tags: tags
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    createAccountCapabilityHost: true
    // Dependent resources
    cosmosDBName: dependencies.outputs.cosmosDBName
    cosmosDBSubscriptionId: dependencies.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: dependencies.outputs.cosmosDBResourceGroupName
    azureStorageName: dependencies.outputs.storageName
    azureStorageSubscriptionId: dependencies.outputs.storageSubscriptionId
    azureStorageResourceGroupName: dependencies.outputs.storageResourceGroupName
    aiSearchName: dependencies.outputs.aiSearchName
    aiSearchServiceSubscriptionId: dependencies.outputs.aiSearchSubscriptionId
    aiSearchServiceResourceGroupName: dependencies.outputs.aiSearchResourceGroupName
  }
}

// ============================================================================
// -- Role Assignments (project identity → dependent resources)
// ============================================================================
module cosmosRoleAssignments './modules/role-assignments.bicep' = {
  name: 'cosmos-role-assignments-${resourceToken}'
  scope: resourceGroup(cosmosSubId, cosmosRgName)
  params: {
    principalId: project.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    cosmosDBName: dependencies.outputs.cosmosDBName
  }
}

module storageRoleAssignments './modules/role-assignments.bicep' = {
  name: 'storage-role-assignments-${resourceToken}'
  scope: resourceGroup(storageSubId, storageRgName)
  params: {
    principalId: project.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    azureStorageName: dependencies.outputs.storageName
  }
}

module searchRoleAssignments './modules/role-assignments.bicep' = {
  name: 'search-role-assignments-${resourceToken}'
  scope: resourceGroup(searchSubId, searchRgName)
  params: {
    principalId: project.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    aiSearchName: dependencies.outputs.aiSearchName
  }
}

// ============================================================================
// -- APIM Connection (to existing APIM)
// ============================================================================

// Reference the existing APIM to build target URL and get subscription key
resource existingApim 'Microsoft.ApiManagement/service@2021-08-01' existing = {
  name: apimServiceName
  scope: resourceGroup(apimSubscriptionId, apimResourceGroupName)
}

resource existingApimApi 'Microsoft.ApiManagement/service/apis@2021-08-01' existing = {
  name: apimApiName
  parent: existingApim
}

resource apimSub 'Microsoft.ApiManagement/service/subscriptions@2021-08-01' existing = if (!empty(apimSubscriptionName)) {
  name: apimSubscriptionName
  parent: existingApim
}

var gatewayUrl = !empty(apimCustomDomainGatewayUrl) ? apimCustomDomainGatewayUrl : existingApim.properties.gatewayUrl
var apimTargetUrl = '${gatewayUrl}/${existingApimApi.properties.path}'
var subscriptionKey = !empty(apimSubscriptionName) ? apimSub.listSecrets(apimSub.apiVersion).primaryKey : ''

var baseMetadata = {
  deploymentInPath: 'true'
  inferenceAPIVersion: inferenceAPIVersion
  models: string(staticModels)
}

var customHeadersMetadata = apimAuthType == 'ProjectManagedIdentity' && !empty(apimSubscriptionName)
  ? { customHeaders: string({ 'api-key': subscriptionKey }) }
  : {}

var apimConnectionMetadata = union(baseMetadata, customHeadersMetadata)

module apimConnection './modules/connection-apim.bicep' = {
  name: 'apim-connection-${resourceToken}'
  params: {
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectName: project.outputs.FOUNDRY_PROJECT_NAME
    connectionName: 'apim-gateway-${resourceToken}'
    target: apimTargetUrl
    authType: apimAuthType
    metadata: apimConnectionMetadata
    subscriptionKey: apimAuthType == 'ApiKey' ? subscriptionKey : null
  }
}

// ============================================================================
// -- Outputs
// ============================================================================
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_PROJECT_NAME string = project.outputs.FOUNDRY_PROJECT_NAME
output FOUNDRY_PROJECT_CONNECTION_STRING string = project.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output APIM_GATEWAY_URL string = gatewayUrl
output APIM_CONNECTION_NAME string = apimConnection.outputs.connectionName
output VALIDATION_RESULT bool = _
