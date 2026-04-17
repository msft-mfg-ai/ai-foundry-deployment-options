// ============================================================================
// Dependent Resources — Cosmos DB, Storage Account, AI Search
// ============================================================================
// Creates or references existing dependent resources for Foundry Agent Service.
// Each resource is optional — provide an existing resource ID to skip creation.
// ============================================================================

@description('Azure region of the deployment')
param location string

param tags object = {}

@description('Name of the Cosmos DB account to create (if not providing existing)')
param cosmosDBName string

@description('Name of the storage account to create (if not providing existing)')
@minLength(3)
@maxLength(24)
param azureStorageName string

@description('Name of the AI Search service to create (if not providing existing)')
param aiSearchName string

@description('Existing Cosmos DB resource ID. If provided, skips creation.')
param existingCosmosDBResourceId string = ''

@description('Existing Storage Account resource ID. If provided, skips creation.')
param existingStorageAccountResourceId string = ''

@description('Existing AI Search resource ID. If provided, skips creation.')
param existingAiSearchResourceId string = ''

// -- Flags -------------------------------------------------------------------
var cosmosDBExists = !empty(existingCosmosDBResourceId)
var storageExists = !empty(existingStorageAccountResourceId)
var aiSearchExists = !empty(existingAiSearchResourceId)

// -- Cosmos DB ---------------------------------------------------------------
var cosmosParts = split(existingCosmosDBResourceId, '/')

resource existingCosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = if (cosmosDBExists) {
  name: cosmosParts[8]
  scope: resourceGroup(cosmosParts[2], cosmosParts[4])
}

// regions that do not support Cosmos DB in EUAP or have limited capacity
var canaryRegions = ['eastus2euap', 'centraluseuap']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if (!cosmosDBExists) {
  name: cosmosDBName
  location: cosmosDbRegion
  kind: 'GlobalDocumentDB'
  tags: tags
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Enabled'
    enableFreeTier: false
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

// -- Storage Account ---------------------------------------------------------
var storageParts = split(existingStorageAccountResourceId, '/')

resource existingStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (storageExists) {
  name: storageParts[8]
  scope: resourceGroup(storageParts[2], storageParts[4])
}

// Some regions don't support Standard Zone-Redundant storage
var noZRSRegions = ['southindia', 'westus', 'northcentralus']
var storageSku = contains(noZRSRegions, location) ? { name: 'Standard_GRS' } : { name: 'Standard_ZRS' }

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = if (!storageExists) {
  name: azureStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: storageSku
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    allowSharedKeyAccess: false
  }
}

// -- AI Search ---------------------------------------------------------------
var searchParts = split(existingAiSearchResourceId, '/')

resource existingSearch 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (aiSearchExists) {
  name: searchParts[8]
  scope: resourceGroup(searchParts[2], searchParts[4])
}

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = if (!aiSearchExists) {
  name: aiSearchName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: false
    authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'enabled'
    replicaCount: 1
    semanticSearch: 'disabled'
  }
  sku: {
    name: 'basic'
  }
}

// -- Outputs -----------------------------------------------------------------
output cosmosDBName string = cosmosDBExists ? existingCosmosDB.name : cosmosDB.name
output cosmosDBResourceGroupName string = cosmosDBExists ? cosmosParts[4] : resourceGroup().name
output cosmosDBSubscriptionId string = cosmosDBExists ? cosmosParts[2] : subscription().subscriptionId

output storageName string = storageExists ? existingStorage.name : storageAccount.name
output storageResourceGroupName string = storageExists ? storageParts[4] : resourceGroup().name
output storageSubscriptionId string = storageExists ? storageParts[2] : subscription().subscriptionId

output aiSearchName string = aiSearchExists ? existingSearch.name : aiSearch.name
output aiSearchResourceGroupName string = aiSearchExists ? searchParts[4] : resourceGroup().name
output aiSearchSubscriptionId string = aiSearchExists ? searchParts[2] : subscription().subscriptionId
