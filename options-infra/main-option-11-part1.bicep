// This bicep deploys AI Foundry with EXISTING infrastructure
// Prerequisites:
// 1. Existing Resource group
// 2. Existing VNet with Agent Subnet for Foundry
// 3. Existing AI Search, Cosmos DB and Storage Account with private endpoints available from Foundry VNet. NOTE: cross region, cross VNET traffic involves egress/ingress costs
// 4. Existing AI Services with models deployed in the same region as Foundry (this RG) and with private endpoint in Foundry VNet

import * as types from './modules/types/types.bicep'

targetScope = 'resourceGroup'
param location string = resourceGroup().location

// ============== EXISTING AI Foundry VNet ==============
@description('Name of the EXISTING Foundry Agent Subnet (shared across Foundry projects)')
param existingFoundryAgentSubnetId string

@description('The resource ID of the existing Ai resource - Azure Open AI, AI Services or AI Foundry. WARNING: existing AI Foundry must be in the same region as the location parameter.')
param existingAiResourceId string

@allowed([
  'AzureOpenAI'
  'AIServices'
])
param existingAiResourceKind string = 'AIServices'

@description('EXISTING AI Search Resource Id in Foundry VNet')
param existingAISearchId string = ''

@description('Name of the EXISTING Cosmos DB Id in App VNet')
param existingCosmosDBId string

@description('Name of the EXISTING AI Search Id in App VNet')
// TODO - why there are 2 ai search instances?
param existingAppAISearchId string?

@description('Name of the EXISTING Storage Account Id in App VNet')
param existingStorageId string

// ============== Monitoring ==============
@description('Name of the existing Application Insights')
param existingApplicationInsightsResourceId string

var resourceToken = toLower(uniqueString(resourceGroup().id))

// ==================== CREATED RESOURCES ====================
var existingAiSearchSplit = split(existingAISearchId, '/')
var existingStorageSplit = split(existingStorageId, '/')
var existingCosmosDBSplit = split(existingCosmosDBId, '/')

// ✅ REFERENCE: Use existing AI dependencies from App VNet
// Prepare aiDependencies object manually since we're using existing resources
var aiDependencies types.aiDependenciesType = {
  aiSearch: {
    name: existingAiSearchSplit[8]
    resourceId: existingAISearchId
    resourceGroupName: existingAiSearchSplit[4]
    subscriptionId: existingAiSearchSplit[2]
  }
  azureStorage: {
    name: existingStorageSplit[8]
    resourceId: existingStorageId
    resourceGroupName: existingStorageSplit[4]
    subscriptionId: existingStorageSplit[2]
  }
  cosmosDB: {
    name: existingCosmosDBSplit[8]
    resourceId: existingCosmosDBId
    resourceGroupName: existingCosmosDBSplit[4]
    subscriptionId: existingCosmosDBSplit[2]
  }
}

// ✅ CREATE: AI Foundry instance with OpenAI connection
// TODO: add keyvault integration https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/set-up-key-vault-connection?pivots=bicep
module foundry './modules/ai/ai-foundry.bicep' = {
  name: 'ai-foundry-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Disabled'  // ✅ Changed to Disabled for security
    agentSubnetResourceId: existingFoundryAgentSubnetId
    deployments: []  // ✅ Empty - using existing Azure OpenAI resource
  }
}

// ✅ CREATE: AI Project with connections to existing dependencies AND OpenAI
module project1 './modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-1-with-caphost-${resourceToken}'
  params: {
    foundryName: foundry.outputs.FOUNDRY_NAME
    location: location
    projectId: 1
    aiDependencies: aiDependencies
    existingAiResourceId: existingAiResourceId
    existingAiResourceKind: existingAiResourceKind
    appInsightsResourceId: existingApplicationInsightsResourceId
  }
}

output foundry1_connection_string string = project1.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
