import * as types from '../types/types.bicep'

param location string = resourceGroup().location
param tags object = {}

@description('Name of the AI Foundry account')
param aiAccountName string
param aiAccountNameResourceGroup string = resourceGroup().name
param aiAccountSubscriptionId string = subscription().subscriptionId

@description('The resource ID of the subnet where the private endpoint will be created')
param peSubnetId string
@description('The resource ID of the virtual network where the private endpoint will be created. Required if no existing DNS zones are provided.')
param vnetId string?

@description('ResourceToken for unique resource names')
param resourceToken string

@description('Map of DNS zone FQDNs to resource group names. If provided, reference existing DNS zones in this resource group instead of creating them.')
param existingDnsZones types.DnsZonesType = types.DefaultDNSZones

var aiServicesDnsZoneName = 'privatelink.services.ai.azure.com'
var openAiDnsZoneName = 'privatelink.openai.azure.com'
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'

// ---- DNS Zone Resource Group lookups ----
var aiServicesDnsZone = existingDnsZones[?aiServicesDnsZoneName]
var openAiDnsZone = existingDnsZones[?openAiDnsZoneName]
var cognitiveServicesDnsZone = existingDnsZones[?cognitiveServicesDnsZoneName]

var validDnsConfig = (empty(aiServicesDnsZone) || empty(openAiDnsZone) || empty(cognitiveServicesDnsZone)) && empty(vnetId)
  ? fail('vnetId must be provided if any DNS zones are to be created.')
  : true

// ---- Resource references ----
resource aiAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: aiAccountName
  scope: resourceGroup(aiAccountSubscriptionId, aiAccountNameResourceGroup)
}

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

// ---- DNS VNet Links ----
resource aiServicesLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(aiServicesDnsZone)) {
  parent: aiServicesPrivateDnsZone
  location: 'global'
  name: 'aiServices-${resourceToken}-link'
  tags: tags
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}
resource openAiLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(openAiDnsZone)) {
  parent: openAiPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiServicesOpenAI-${resourceToken}-link'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}
resource cognitiveServicesLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (empty(cognitiveServicesDnsZone)) {
  parent: cognitiveServicesPrivateDnsZone
  location: 'global'
  tags: tags
  name: 'aiServicesCognitiveServices-${resourceToken}-link'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

// Private endpoint for AI Services account
// - Creates network interface in customer hub subnet
// - Establishes private connection to AI Services account
resource aiAccountPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (!empty(aiAccountName)) {
  name: '${aiAccountName}-private-endpoint'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId } // Deploy in customer hub subnet
    privateLinkServiceConnections: [
      {
        name: '${aiAccountName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: aiAccount.id
          groupIds: ['account'] // Target AI Services account
        }
      }
    ]
  }
}

// ---- DNS Zone Groups ----
resource aiServicesDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (!empty(aiAccountName)) {
  parent: aiAccountPrivateEndpoint
  name: '${aiAccountName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${aiAccountName}-dns-aiserv-config', properties: { privateDnsZoneId: aiServicesDnsZoneId } }
      { name: '${aiAccountName}-dns-openai-config', properties: { privateDnsZoneId: openAiDnsZoneId } }
      { name: '${aiAccountName}-dns-cogserv-config', properties: { privateDnsZoneId: cognitiveServicesDnsZoneId } }
    ]
  }
  dependsOn: [
    empty(aiServicesDnsZone) ? aiServicesLink : null
    empty(openAiDnsZone) ? openAiLink : null
    empty(cognitiveServicesDnsZone) ? cognitiveServicesLink : null
  ]
}

output validDnsConfig bool = validDnsConfig
