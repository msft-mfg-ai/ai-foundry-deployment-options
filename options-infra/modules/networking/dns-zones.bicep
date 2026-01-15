import * as types from '../types/types.bicep'

@description('Array of VNet resource IDs to link the Private DNS Zones to for name resolution')
param vnetResourceIds string[] = []

/* -------------------------------------------- Private DNS Zones -------------------------------------------- */

// Format: 1) Private DNS Zone
//         2) Link Private DNS Zone to VNet
//         3) Create DNS Zone Group for Private Endpoint

// Private DNS Zone for AI Services (Account)
// 1) Enables custom DNS resolution for AI Services private endpoint

var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'
var aiSearchDnsZoneName = 'privatelink.search.windows.net'
var storageDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var cosmosDBDnsZoneName = 'privatelink.documents.azure.com'
var keyVaultDnsZoneName = 'privatelink.vaultcore.azure.net'

// ---- DNS Zone Resources and References ----
resource aiServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiServicesDnsZoneName
  location: 'global'
}

resource openAiPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: openAiDnsZoneName
  location: 'global'
}

resource cognitiveServicesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cognitiveServicesDnsZoneName
  location: 'global'
}

resource aiSearchPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: aiSearchDnsZoneName
  location: 'global'
}

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: storageDnsZoneName
  location: 'global'
}

resource cosmosDBPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: cosmosDBDnsZoneName
  location: 'global'
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: keyVaultDnsZoneName
  location: 'global'
}

// ---- DNS VNet Links ----
resource aiServicesLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: aiServicesPrivateDnsZone
    location: 'global'
    name: 'aiServices-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource openAiLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: openAiPrivateDnsZone
    location: 'global'
    name: 'aiServicesOpenAI-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource cognitiveServicesLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: cognitiveServicesPrivateDnsZone
    location: 'global'
    name: 'aiServicesCognitiveServices-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource aiSearchLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: aiSearchPrivateDnsZone
    location: 'global'
    name: 'aiSearch-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource storageLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: storagePrivateDnsZone
    location: 'global'
    name: 'storage-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource keyVaultLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: keyVaultPrivateDnsZone
    location: 'global'
    name: 'keyVault-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

resource cosmosDBLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for vnetId in vnetResourceIds: {
    parent: cosmosDBPrivateDnsZone
    location: 'global'
    name: 'cosmosDB-${uniqueString(vnetId)}-link'
    properties: {
      virtualNetwork: { id: vnetId }
      registrationEnabled: false
    }
  }
]

output AI_SERVICES_PRIVATE_DNS_ZONE_RESOURCE_ID string = aiServicesPrivateDnsZone.id
output OPENAI_PRIVATE_DNS_ZONE_RESOURCE_ID string = openAiPrivateDnsZone.id
output COGNITIVE_SERVICES_PRIVATE_DNS_ZONE_RESOURCE_ID string = cognitiveServicesPrivateDnsZone.id
output AI_SEARCH_PRIVATE_DNS_ZONE_RESOURCE_ID string = aiSearchPrivateDnsZone.id
output STORAGE_PRIVATE_DNS_ZONE_RESOURCE_ID string = storagePrivateDnsZone.id
output COSMOS_DB_PRIVATE_DNS_ZONE_RESOURCE_ID string = cosmosDBPrivateDnsZone.id
output KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_ID string = keyVaultPrivateDnsZone.id

@description('Dictionary of Private DNS Zones created')
output DNS_ZONES types.DnsZonesType = {
  'privatelink.services.ai.azure.com': {
    name: aiServicesDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: aiServicesPrivateDnsZone.id
  }
  'privatelink.openai.azure.com': {
    name: openAiDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: openAiPrivateDnsZone.id
  }
  'privatelink.cognitiveservices.azure.com': {
    name: cognitiveServicesDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: cognitiveServicesPrivateDnsZone.id
  }
  'privatelink.search.windows.net': {
    name: aiSearchDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: aiSearchPrivateDnsZone.id
  }
  'privatelink.blob.${environment().suffixes.storage}': {
    name: storageDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: storagePrivateDnsZone.id
  }
  'privatelink.documents.azure.com': {
    name: cosmosDBDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: cosmosDBPrivateDnsZone.id
  }
  'privatelink.vaultcore.azure.net': {
    name: keyVaultDnsZoneName
    resourceGroupName: resourceGroup().name
    subscriptionId: subscription().subscriptionId
    resourceId: keyVaultPrivateDnsZone.id
  }
}
