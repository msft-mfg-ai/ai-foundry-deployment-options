param tags object = {}
param peSubnetResourceId string
param apimName string
param apimResourceGroup string = resourceGroup().name
param apimSubsciptionId string = subscription().subscriptionId
param location string = resourceGroup().location

var subnetIdParts = split(peSubnetResourceId, '/')
var subnetName = last(subnetIdParts)
var vnetResourceId = substring(peSubnetResourceId, 0, length(peSubnetResourceId) - length('/subnets/${subnetName}'))

var vnetLinks = empty(vnetResourceId)
  ? []
  : [
      {
        virtualNetworkResourceId: vnetResourceId
      }
    ]

module azure_api_net_DnsZone 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'privatelink-azure-api-net-privateDnsZoneDeployment'
  params: {
    tags: tags
    // Required parameters
    name: 'privatelink.azure-api.net'
    // Non-required parameters
    location: 'global'
    virtualNetworkLinks: vnetLinks
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
  scope: resourceGroup(apimSubsciptionId, apimResourceGroup)
}

resource apimPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${apimName}-private-endpoint'
  location: location
  properties: {
    subnet: { id: peSubnetResourceId }
    privateLinkServiceConnections: [
      {
        name: '${apimName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: apim.id
          groupIds: ['Gateway'] // Target API Management gateway
        }
      }
    ]
  }
}

// ---- DNS Zone Groups ----
resource apimServiceDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: apimPrivateEndpoint
  name: '${apimName}-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      { name: '${apimName}-dns-aiserv-config', properties: { privateDnsZoneId: azure_api_net_DnsZone.outputs.resourceId } }
    ]
  }
}
