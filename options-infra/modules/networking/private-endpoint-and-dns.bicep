import * as types from '../types/types.bicep'
/*
Private Endpoint and DNS Configuration Module
------------------------------------------
This module configures private network access for Azure services using:

1. Private Endpoints:
   - Creates network interfaces in the specified subnet
   - Establishes private connections to Azure services
   - Enables secure access without public internet exposure

2. Private DNS Zones:
   - Enables custom DNS resolution for private endpoints

3. DNS Zone Links:
   - Links private DNS zones to the VNet
   - Enables name resolution for resources in the VNet
   - Prevents DNS resolution conflicts

Security Benefits:
- Eliminates public internet exposure
- Enables secure access from within VNet
- Prevents data exfiltration through network
*/

// Resource names and identifiers
@description('Name of the AI Foundry account')
param aiAccountName string?
param location string = resourceGroup().location
param tags object = {}
param aiAccountNameResourceGroup string = resourceGroup().name
param aiAccountSubscriptionId string = subscription().subscriptionId
@description('Name of the AI Search service')
param aiSearchName string
@description('Name of the storage account')
param storageName string
@description('Name of the Cosmos DB account')
param cosmosDBName string
@description('Name of the Vnet')
param vnetName string
@description('Name of the Customer subnet')
param peSubnetName string
@description('Suffix for unique resource names')
param suffix string

@description('Resource Group name for existing Virtual Network (if different from current resource group)')
param vnetResourceGroupName string = resourceGroup().name

@description('Subscription ID for Virtual Network')
param vnetSubscriptionId string = subscription().subscriptionId

@description('Resource Group name for Storage Account')
param storageAccountResourceGroupName string = resourceGroup().name

@description('Subscription ID for Storage account')
param storageAccountSubscriptionId string = subscription().subscriptionId

@description('Subscription ID for AI Search service')
param aiSearchSubscriptionId string = subscription().subscriptionId

@description('Resource Group name for AI Search service')
param aiSearchResourceGroupName string = resourceGroup().name

@description('Subscription ID for Cosmos DB account')
param cosmosDBSubscriptionId string = subscription().subscriptionId

@description('Resource group name for Cosmos DB account')
param cosmosDBResourceGroupName string = resourceGroup().name

@description('Map of DNS zone FQDNs to resource group names. If provided, reference existing DNS zones in this resource group instead of creating them.')
param existingDnsZones types.DnsZonesType = types.DefaultDNSZones

module ai_private_endpoint 'ai-pe-dns.bicep' = if (!empty(aiAccountName)) {
  name: '${aiAccountName}-private-endpoint'
  params: {
    tags: tags
    aiAccountName: aiAccountName!
    aiAccountNameResourceGroup: aiAccountNameResourceGroup
    aiAccountSubscriptionId: aiAccountSubscriptionId
    peSubnetId: peSubnet.id
    resourceToken: suffix
    vnetId: vnet.id
    existingDnsZones: zones
  }
  dependsOn: [
      openAiPrivateDnsZone
      cognitiveServicesPrivateDnsZone
      aiServicesPrivateDnsZone
    ]
}


resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: aiSearchName
  scope: resourceGroup(aiSearchSubscriptionId, aiSearchResourceGroupName)
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
  scope: resourceGroup(storageAccountSubscriptionId, storageAccountResourceGroupName)
}

resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosDBName
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}

// Reference existing network resources
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetSubscriptionId, vnetResourceGroupName)
}
resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: peSubnetName
}

/* -------------------------------------------- AI Search Private Endpoint -------------------------------------------- */

// Private endpoint for AI Search
// - Creates network interface in customer hub subnet
// - Establishes private connection to AI Search service
resource aiSearchPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${aiSearchName}-private-endpoint'
  location: location
    tags: tags
  properties: {
    subnet: { id: peSubnet.id } // Deploy in customer hub subnet
    privateLinkServiceConnections: [
      {
        name: '${aiSearchName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: aiSearch.id
          groupIds: ['searchService'] // Target search service
        }
      }
    ]
  }
}

/* -------------------------------------------- Storage Private Endpoint -------------------------------------------- */

// Private endpoint for Storage Account
// - Creates network interface in customer hub subnet
// - Establishes private connection to blob storage
resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${storageName}-private-endpoint'
  location: location
    tags: tags
  properties: {
    subnet: { id: peSubnet.id } // Deploy in customer hub subnet
    privateLinkServiceConnections: [
      {
        name: '${storageName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: storageAccount.id // Target blob storage
          groupIds: ['blob']
        }
      }
    ]
  }
}

/*--------------------------------------------- Cosmos DB Private Endpoint -------------------------------------*/

resource cosmosDBPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${cosmosDBName}-private-endpoint'
  location: location
    tags: tags
  properties: {
    subnet: { id: peSubnet.id } // Deploy in customer hub subnet
    privateLinkServiceConnections: [
      {
        name: '${cosmosDBName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: cosmosDBAccount.id // Target Cosmos DB account
          groupIds: ['Sql']
        }
      }
    ]
  }
}

/* -------------------------------------------- Private DNS Zones -------------------------------------------- */

// Format: 1) Private DNS Zone
//         2) Link Private DNS Zone to VNet
//         3) Create DNS Zone Group for Private Endpoint

// Private DNS Zone for AI Services (Account)
// 1) Enables custom DNS resolution for AI Services private endpoint

var aiSearchDnsZoneName = 'privatelink.search.windows.net'
var storageDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var cosmosDBDnsZoneName = 'privatelink.documents.azure.com'
var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'
var keyVaultDnsZoneName = 'privatelink.vaultcore.azure.net'

// ---- DNS Zone Resource Group lookups ----
var aiSearchDnsZone = existingDnsZones[?aiSearchDnsZoneName]
var storageDnsZone = existingDnsZones[?storageDnsZoneName]
var cosmosDBDnsZone = existingDnsZones[?cosmosDBDnsZoneName]
var aiServicesDnsZone = existingDnsZones[?aiServicesDnsZoneName]
var openAiDnsZone = existingDnsZones[?openAiDnsZoneName]
var cognitiveServicesDnsZone = existingDnsZones[?cognitiveServicesDnsZoneName]
var keyVaultDnsZone = existingDnsZones[?keyVaultDnsZoneName]

// ---- DNS Zone Resources and References ----
resource aiServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(aiServicesDnsZone)) {
  name: aiServicesDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingAiServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(aiServicesDnsZone)) {
  name: aiServicesDnsZoneName
  scope: resourceGroup(aiServicesDnsZone!.subscriptionId, aiServicesDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var aiServicesDnsZoneId = empty(aiServicesDnsZone) ? aiServicesPrivateDnsZone.id : existingAiServicesPrivateDnsZone.id

resource openAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(openAiDnsZone)) {
  name: openAiDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingOpenAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(openAiDnsZone)) {
  name: openAiDnsZoneName
  scope: resourceGroup(openAiDnsZone!.subscriptionId, openAiDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var openAiDnsZoneId = empty(openAiDnsZone) ? openAiPrivateDnsZone.id : existingOpenAiPrivateDnsZone.id

resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(cognitiveServicesDnsZone)) {
  name: cognitiveServicesDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingCognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(cognitiveServicesDnsZone)) {
  name: cognitiveServicesDnsZoneName
  scope: resourceGroup(cognitiveServicesDnsZone!.subscriptionId, cognitiveServicesDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var cognitiveServicesDnsZoneId = empty(cognitiveServicesDnsZone)
  ? cognitiveServicesPrivateDnsZone.id
  : existingCognitiveServicesPrivateDnsZone.id

resource aiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(aiSearchDnsZone)) {
  name: aiSearchDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingAiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(aiSearchDnsZone)) {
  name: aiSearchDnsZoneName
  scope: resourceGroup(aiSearchDnsZone!.subscriptionId, aiSearchDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var aiSearchDnsZoneId = empty(aiSearchDnsZone) ? aiSearchPrivateDnsZone.id : existingAiSearchPrivateDnsZone.id

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(storageDnsZone)) {
  name: storageDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingStoragePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(storageDnsZone)) {
  name: storageDnsZoneName
  scope: resourceGroup(storageDnsZone!.subscriptionId, storageDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var storageDnsZoneId = empty(storageDnsZone) ? storagePrivateDnsZone.id : existingStoragePrivateDnsZone.id

resource cosmosDBPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(cosmosDBDnsZone)) {
  name: cosmosDBDnsZoneName
  location: 'global'
  tags: tags
}

// Reference existing private DNS zone if provided
resource existingCosmosDBPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(cosmosDBDnsZone)) {
  name: cosmosDBDnsZoneName
  scope: resourceGroup(cosmosDBDnsZone!.subscriptionId, cosmosDBDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var cosmosDBDnsZoneId = empty(cosmosDBDnsZone) ? cosmosDBPrivateDnsZone.id : existingCosmosDBPrivateDnsZone.id

// Reference existing private DNS zone if provided
resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (empty(keyVaultDnsZone)) {
  name: keyVaultDnsZoneName
  location: 'global'
  tags: tags
}

resource existingKeyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!empty(keyVaultDnsZone)) {
  name: keyVaultDnsZoneName
  scope: resourceGroup(keyVaultDnsZone!.subscriptionId, keyVaultDnsZone!.resourceGroupName)
}
//creating condition if user pass existing dns zones or not
var keyVaultDnsZoneId = empty(keyVaultDnsZone) ? keyVaultPrivateDnsZone.id : existingKeyVaultPrivateDnsZone.id

// ---- DNS VNet Links ----
resource aiServicesLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(aiServicesDnsZone)) {
  parent: aiServicesPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiServices-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
resource openAiLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(openAiDnsZone)) {
  parent: openAiPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiServicesOpenAI-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
resource cognitiveServicesLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(cognitiveServicesDnsZone)) {
  parent: cognitiveServicesPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiServicesCognitiveServices-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource aiSearchLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(aiSearchDnsZone)) {
  parent: aiSearchPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiSearch-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
resource storageLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(storageDnsZone)) {
  parent: storagePrivateDnsZone
  location: 'global'
  tags: tags
  name: 'storage-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}
resource cosmosDBLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(cosmosDBDnsZone)) {
  parent: cosmosDBPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'cosmosDB-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource keyVaultLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(keyVaultDnsZone)) {
  parent: keyVaultPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'keyVault-${suffix}-link'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// ---- DNS Zone Groups ----

resource aiSearchDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: aiSearchPrivateEndpoint
  name: '${aiSearchName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${aiSearchName}-dns-config', properties: { privateDnsZoneId: aiSearchDnsZoneId } }
    ]
  }
  dependsOn: [
    empty(aiSearchDnsZone) ? aiSearchLink : null
  ]
}
resource storageDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: '${storageName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${storageName}-dns-config', properties: { privateDnsZoneId: storageDnsZoneId } }
    ]
  }
  dependsOn: [
    empty(storageDnsZone) ? storageLink : null
  ]
}
resource cosmosDBDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosDBPrivateEndpoint
  name: '${cosmosDBName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${cosmosDBName}-dns-config', properties: { privateDnsZoneId: cosmosDBDnsZoneId } }
    ]
  }
  dependsOn: [
    empty(cosmosDBDnsZone) ? cosmosDBLink : null
  ]
}


output aiServicesDnsZoneId string = aiServicesDnsZoneId
output openAiDnsZoneId string = openAiDnsZoneId
output cognitiveServicesDnsZoneId string = cognitiveServicesDnsZoneId
var zones types.DnsZonesType = {
  'privatelink.services.ai.azure.com': {
    name: aiServicesDnsZoneName
    resourceGroupName: empty(aiServicesDnsZone) ? resourceGroup().name : aiServicesDnsZone!.resourceGroupName
    subscriptionId: empty(aiServicesDnsZone) ? subscription().subscriptionId : aiServicesDnsZone!.subscriptionId
    resourceId: aiServicesDnsZoneId
  }
  'privatelink.openai.azure.com': {
    name: openAiDnsZoneName
    resourceGroupName: empty(openAiDnsZone) ? resourceGroup().name : openAiDnsZone!.resourceGroupName
    subscriptionId: empty(openAiDnsZone) ? subscription().subscriptionId : openAiDnsZone!.subscriptionId
    resourceId: openAiDnsZoneId
  }
  'privatelink.cognitiveservices.azure.com': {
    name: cognitiveServicesDnsZoneName
    resourceGroupName: empty(cognitiveServicesDnsZone) ? resourceGroup().name : cognitiveServicesDnsZone!.resourceGroupName
    subscriptionId: empty(cognitiveServicesDnsZone) ? subscription().subscriptionId : cognitiveServicesDnsZone!.subscriptionId
    resourceId: cognitiveServicesDnsZoneId
  }
  'privatelink.search.windows.net': {
    name: aiSearchDnsZoneName
    resourceGroupName: empty(aiSearchDnsZone) ? resourceGroup().name : aiSearchDnsZone!.resourceGroupName
    subscriptionId: empty(aiSearchDnsZone) ? subscription().subscriptionId : aiSearchDnsZone!.subscriptionId
    resourceId: aiSearchDnsZoneId
  }
  'privatelink.blob.${environment().suffixes.storage}': {
    name: storageDnsZoneName
    resourceGroupName: empty(storageDnsZone) ? resourceGroup().name : storageDnsZone!.resourceGroupName
    subscriptionId: empty(storageDnsZone) ? subscription().subscriptionId : storageDnsZone!.subscriptionId
    resourceId: storageDnsZoneId
  }
  'privatelink.documents.azure.com': {
    name: cosmosDBDnsZoneName
    resourceGroupName: empty(cosmosDBDnsZone) ? resourceGroup().name : cosmosDBDnsZone!.resourceGroupName
    subscriptionId: empty(cosmosDBDnsZone) ? subscription().subscriptionId : cosmosDBDnsZone!.subscriptionId
    resourceId: cosmosDBDnsZoneId
  }
  'privatelink.vaultcore.azure.net': {
    name: 'privatelink.vaultcore.azure.net'
    resourceGroupName: empty(keyVaultDnsZone) ? resourceGroup().name : keyVaultDnsZone!.resourceGroupName
    subscriptionId: empty(keyVaultDnsZone) ? subscription().subscriptionId : keyVaultDnsZone!.subscriptionId
    resourceId: keyVaultDnsZoneId
  }
}

output DNSZones types.DnsZonesType = zones
