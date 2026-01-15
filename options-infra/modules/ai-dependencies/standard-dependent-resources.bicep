// Creates Azure dependent resources for Azure AI Agent Service standard agent setup
import * as types from '../types/types.bicep'

@description('Azure region of the deployment')
param location string

param tags object = {}
var defaultTags = union(tags, {
  deployedBy: 'ai-foundry-infra'
  'hidden-title': 'Foundry Dependent Resources'
})

@description('The name of the AI Search resource')
param aiSearchName string

@description('Name of the storage account')
@minLength(3)
@maxLength(24)
param azureStorageName string

@description('Name of the new Cosmos DB account')
param cosmosDBName string

@description('The AI Search Service full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param aiSearchResourceId string?

@description('The AI Storage Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param azureStorageAccountResourceId string?

@description('The Cosmos DB Account full ARM Resource ID. This is an optional field, and if not provided, the resource will be created.')
param cosmosDBResourceId string?

var aiSearchExists bool = !empty(aiSearchResourceId)
var azureStorageExists bool = !empty(azureStorageAccountResourceId)
var cosmosDBExists bool = !empty(cosmosDBResourceId)

var aiSearchIsValid = aiSearchExists && aiSearchName != last(aiSearchParts)
  ? fail('The existing AI Search resource name must match the aiSearchName parameter.')
  : true
var storageIsValid = azureStorageExists && azureStorageName != last(azureStorageParts)
  ? fail('The existing Storage Account name must match the azureStorageName parameter.')
  : true
var cosmosIsValid = cosmosDBExists && cosmosDBName != last(cosmosParts)
  ? fail('The existing Cosmos DB account name must match the cosmosDBName parameter.')
  : true

// Cosmos check
var cosmosParts = split(cosmosDBResourceId ?? '', '/')

resource existingCosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (cosmosDBExists) {
  name: last(cosmosParts)
  scope: resourceGroup(cosmosParts[2], cosmosParts[4])
}

// CosmosDB creation

// regions that do not support Cosmos DB in EUAP or have limited capacity
var canaryRegions = ['eastus2euap', 'centraluseuap']
// TODO: fix if capacity issue is resolved
var lowCapacityRegions = ['eastus', 'northeurope', 'westeurope']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if(!cosmosDBExists) {
  name: cosmosDBName
  location: cosmosDbRegion
  kind: 'GlobalDocumentDB'
  tags: defaultTags
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    locations: [
      {
        locationName: contains(lowCapacityRegions, location) ? 'eastus2' : location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

// AI Search check

var aiSearchParts = split(aiSearchResourceId ?? '', '/')

resource existingSearchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (aiSearchExists) {
  name: last(aiSearchParts)
  scope: resourceGroup(aiSearchParts[2], aiSearchParts[4])
}

// AI Search creation

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = if(!aiSearchExists) {
  name: aiSearchName
  location: location
  tags: defaultTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: false
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge'}}
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'disabled'
    replicaCount: 1
    semanticSearch: 'disabled'
    networkRuleSet: {
      bypass: 'None'
      ipRules: []
    }
  }
  sku: {
    name: 'basic'
  }
}

// Storage Account check

var azureStorageParts = split(azureStorageAccountResourceId ?? '', '/')

resource existingAzureStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (azureStorageExists) {
  name: last(azureStorageParts)
  scope: resourceGroup(azureStorageParts[2], azureStorageParts[4])
}

// Some regions doesn't support Standard Zone-Redundant storage, need to use Geo-redundant storage
param noZRSRegions array = ['southindia', 'westus']
param sku object = contains(noZRSRegions, location) ? { name: 'Standard_GRS' } : { name: 'Standard_ZRS' }

// Storage creation

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if(!azureStorageExists) {
  name: azureStorageName
  location: location
  tags: defaultTags
  kind: 'StorageV2'
  sku: sku
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
    }
    allowSharedKeyAccess: false
  }
}

var aiSearchNameFinal string = aiSearchExists ? existingSearchService.name : aiSearch.name
var aiSearchID string = aiSearchExists ? existingSearchService.id : aiSearch.id
var aiSearchServiceResourceGroupName string = aiSearchExists ? aiSearchParts[4] : resourceGroup().name
var aiSearchServiceSubscriptionId string = aiSearchExists ? aiSearchParts[2] : subscription().subscriptionId

var azureStorageNameFinal string = azureStorageExists ? existingAzureStorageAccount.name :  storage.name
var azureStorageId string =  azureStorageExists ? existingAzureStorageAccount.id :  storage.id
var azureStorageResourceGroupName string = azureStorageExists ? azureStorageParts[4] : resourceGroup().name
var azureStorageSubscriptionId string = azureStorageExists ? azureStorageParts[2] : subscription().subscriptionId

var cosmosDBNameFinal string = cosmosDBExists ? existingCosmosDB.name : cosmosDB.name
var cosmosDBId string = cosmosDBExists ? existingCosmosDB.id : cosmosDB.id
var cosmosDBResourceGroupName string = cosmosDBExists ? cosmosParts[4] : resourceGroup().name
var cosmosDBSubscriptionId string = cosmosDBExists ? cosmosParts[2] : subscription().subscriptionId


output AI_DEPENDENCIES_VALID bool = aiSearchIsValid && storageIsValid && cosmosIsValid
output AI_SEARCH_NAME string = aiSearchNameFinal
output AI_SEARCH_RESOURCE_ID string = aiSearchID
output AI_SEARCH_RESOURCE_GROUP_NAME string = aiSearchServiceResourceGroupName
output AI_SEARCH_SUBSCRIPTION_ID string = aiSearchServiceSubscriptionId

output STORAGE_NAME string = azureStorageNameFinal
output STORAGE_RESOURCE_ID string = azureStorageId
output STORAGE_RESOURCE_GROUP_NAME string =azureStorageResourceGroupName
output STORAGE_SUBSCRIPTION_ID string = azureStorageSubscriptionId

output COSMOS_DB_NAME string = cosmosDBNameFinal
output COSMOS_DB_RESOURCE_ID string = cosmosDBId
output COSMOS_DB_RESOURCE_GROUP_NAME string = cosmosDBResourceGroupName
output COSMOS_DB_SUBSCRIPTION_ID string = cosmosDBSubscriptionId

output AI_DEPENDENCIES types.aiDependenciesType = {
  aiSearch: {
    name: aiSearchNameFinal
    resourceId: aiSearchID
    resourceGroupName: aiSearchServiceResourceGroupName
    subscriptionId: aiSearchServiceSubscriptionId
  }
  azureStorage: {
    name: azureStorageNameFinal
    resourceId: azureStorageId
    resourceGroupName: azureStorageResourceGroupName
    subscriptionId: azureStorageSubscriptionId
  }
  cosmosDB: {
    name: cosmosDBNameFinal
    resourceId: cosmosDBId
    resourceGroupName: cosmosDBResourceGroupName
    subscriptionId: cosmosDBSubscriptionId
  }
}
