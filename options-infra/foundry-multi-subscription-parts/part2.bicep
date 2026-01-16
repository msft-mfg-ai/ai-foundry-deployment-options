// This bicep creates private endpoint for AI Foundry
import * as types from '../modules/types/types.bicep'

targetScope = 'resourceGroup'

@description('Name of the EXISTING Private endpoint Subnet in App VNet')
param peSubnetId string

// ============== EXISTING AI Foundry VNet ==============
@description('The resource ID of the existing Ai resource - Azure Open AI, AI Services or AI Foundry. WARNING: existing AI Foundry must be in the same region as the location parameter.')
param existingAiResourceId string

// ============== DNS Subscription ==============
param dnsSubscriptionId string
param dnsResourceGroupName string = 'rg-private-dns'

var resourceToken = toLower(uniqueString(resourceGroup().id))
var existingAiResourceSplit = split(existingAiResourceId, '/')

// -------- DNS ------------
var existingDnsZonesConfig types.DnsZonesType = {
  'privatelink.services.ai.azure.com': {
    name: 'privatelink.services.ai.azure.com'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
  }
  'privatelink.openai.azure.com': {
    name: 'privatelink.openai.azure.com'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
  }
  'privatelink.cognitiveservices.azure.com': {
    name: 'privatelink.cognitiveservices.azure.com'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
  }
  'privatelink.search.windows.net': {
    name: 'privatelink.search.windows.net'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
  }
  'privatelink.blob.${environment().suffixes.storage}': {
    name: 'privatelink.blob.${environment().suffixes.storage}'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
  }
  'privatelink.documents.azure.com': {
    name: 'privatelink.documents.azure.com'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
  }
  'privatelink.vaultcore.azure.net': {
    name: 'privatelink.vaultcore.azure.net'
    resourceGroupName: dnsResourceGroupName
    subscriptionId: dnsSubscriptionId
    resourceId: resourceId(dnsSubscriptionId, dnsResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net')
  }
}

module foundry_private_endpoint '../modules/networking/ai-pe-dns.bicep' = {
  name: 'foundry-private-endpoint'
  params: {
    aiAccountName: existingAiResourceSplit[8]
    aiAccountNameResourceGroup: existingAiResourceSplit[4]
    aiAccountSubscriptionId: existingAiResourceSplit[2]
    peSubnetId: peSubnetId
    resourceToken: resourceToken
    vnetId: null
    existingDnsZones: existingDnsZonesConfig
  }
}
