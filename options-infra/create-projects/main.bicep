import * as types from '../modules/types/types.bicep'

param location string = resourceGroup().location
param foundryName string

@description('EXISTING AI Search Resource Id in Foundry VNet')
param existingAISearchId string

@description('Name of the EXISTING Cosmos DB Id in App VNet')
param existingCosmosDBId string

@description('Name of the EXISTING Storage Account Id in App VNet')
param existingStorageId string

@description('Optional EXISTING Application Insights resource id. When provided, the project MI is granted read access on it so evaluation can read agent traces.')
param existingApplicationInsightsResourceId string = ''

// validation
var is_valid = empty(foundryName) || empty(existingAISearchId) || empty(existingCosmosDBId) || empty(existingStorageId)
  ? fail('FOUNDRY_NAME, EXISTING_AI_SEARCH_ID, EXISTING_COSMOS_ID, EXISTING_STORAGE_ID are required')
  : true

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

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(2, 4): {
    name: 'ai-project-${i}-with-caphost'
    params: {
      foundryName: foundryName
      location: location
      projectId: i
      aiDependencies: aiDependencies
      existingAiResourceId: null // can provide existing AI resource in the same region
      managedIdentityResourceId: null // can provide user-assigned identity here
      appInsightsResourceId: empty(existingApplicationInsightsResourceId) ? null : existingApplicationInsightsResourceId
    }
  }
]

output is_valid bool = is_valid
