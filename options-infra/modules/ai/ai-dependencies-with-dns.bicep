import * as types from '../types/types.bicep'
param location string = resourceGroup().location
param tags object = {}
param resourceToken string
param aiServicesName string
param aiAccountNameResourceGroupName string

param vnetResourceId string
param peSubnetName string

param azureStorageName string = 'projstorage${resourceToken}'
param aiSearchName string = 'project-search-${resourceToken}'
param cosmosDBName string = 'project-cosmosdb-${resourceToken}'

param azureStorageId string?
param aiSearchId string?
param cosmosDBId string?

var vnetParts = split(vnetResourceId, '/')
var vnetSubscriptionId = vnetParts[2]
var vnetResourceGroupName = vnetParts[4]
var existingVnetName = last(vnetParts)
var vnetName = trim(existingVnetName)


module ai_dependencies '../ai-dependencies/standard-dependent-resources.bicep' = {
  name: 'ai-dependencies-deployment'
  params: {
    location: location
    tags: tags
    azureStorageName: azureStorageName
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName

    // AI Search Service parameters
    aiSearchResourceId: aiSearchId

    // Storage Account
    azureStorageAccountResourceId: azureStorageId

    // Cosmos DB Account
    cosmosDBResourceId: cosmosDBId
  }
}

// Private Endpoint and DNS Configuration
// This module sets up private network access for all Azure services:
// 1. Creates private endpoints in the specified subnet
// 2. Sets up private DNS zones for each service
// 3. Links private DNS zones to the VNet for name resolution
// 4. Configures network policies to restrict access to private endpoints only
module privateEndpointAndDNS '../networking/private-endpoint-and-dns.bicep' = {
  name: 'private-endpoints-and-dns-deployment'
  params: {
    tags: tags
    aiAccountName: aiServicesName // AI Services to secure
    aiAccountNameResourceGroup: aiAccountNameResourceGroupName
    #disable-next-line what-if-short-circuiting
    aiSearchName: ai_dependencies.outputs.AI_SEARCH_NAME // AI Search to secure
    #disable-next-line what-if-short-circuiting
    storageName: ai_dependencies.outputs.STORAGE_NAME // Storage to secure
    #disable-next-line what-if-short-circuiting
    cosmosDBName: ai_dependencies.outputs.COSMOS_DB_NAME
    vnetName: vnetName // VNet containing subnets
    peSubnetName: peSubnetName // Subnet for private endpoints
    suffix: resourceToken // Unique identifier
    vnetResourceGroupName: vnetResourceGroupName // Resource Group for the VNet
    vnetSubscriptionId: vnetSubscriptionId // Subscription ID for the VNet
    #disable-next-line what-if-short-circuiting
    cosmosDBSubscriptionId: ai_dependencies.outputs.COSMOS_DB_SUBSCRIPTION_ID // Subscription ID for Cosmos DB
    #disable-next-line what-if-short-circuiting
    cosmosDBResourceGroupName: ai_dependencies.outputs.COSMOS_DB_RESOURCE_GROUP_NAME // Resource Group for Cosmos DB
    #disable-next-line what-if-short-circuiting
    aiSearchSubscriptionId: ai_dependencies.outputs.AI_SEARCH_SUBSCRIPTION_ID // Subscription ID for AI Search Service
    #disable-next-line what-if-short-circuiting
    aiSearchResourceGroupName: ai_dependencies.outputs.AI_SEARCH_RESOURCE_GROUP_NAME // Resource Group for AI Search Service
    #disable-next-line what-if-short-circuiting
    storageAccountResourceGroupName: ai_dependencies.outputs.STORAGE_RESOURCE_GROUP_NAME // Resource Group for Storage Account
    #disable-next-line what-if-short-circuiting
    storageAccountSubscriptionId: ai_dependencies.outputs.STORAGE_SUBSCRIPTION_ID // Subscription ID for Storage Account
  }
}

output DNS_ZONES types.DnsZonesType = privateEndpointAndDNS.outputs.DNSZones
@description('AI Dependencies (search, storage, cosmos) output including resource details')
output AI_DEPENDECIES types.aiDependenciesType = {
  aiSearch: {
    name: ai_dependencies.outputs.AI_SEARCH_NAME
    resourceId: ai_dependencies.outputs.AI_SEARCH_RESOURCE_ID
    resourceGroupName: ai_dependencies.outputs.AI_SEARCH_RESOURCE_GROUP_NAME
    subscriptionId: ai_dependencies.outputs.AI_SEARCH_SUBSCRIPTION_ID
  }
  azureStorage: {
    name: ai_dependencies.outputs.STORAGE_NAME
    resourceId: ai_dependencies.outputs.STORAGE_RESOURCE_ID
    resourceGroupName: ai_dependencies.outputs.STORAGE_RESOURCE_GROUP_NAME
    subscriptionId: ai_dependencies.outputs.STORAGE_SUBSCRIPTION_ID
  }
  cosmosDB: {
    name: ai_dependencies.outputs.COSMOS_DB_NAME
    resourceId: ai_dependencies.outputs.COSMOS_DB_RESOURCE_ID
    resourceGroupName: ai_dependencies.outputs.COSMOS_DB_RESOURCE_GROUP_NAME
    subscriptionId: ai_dependencies.outputs.COSMOS_DB_SUBSCRIPTION_ID
  }
}


