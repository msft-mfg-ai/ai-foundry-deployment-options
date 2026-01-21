param location string
param tags object = {}
param securityGroupName string
param virtualNetworkName string
param amlSubnetName string = 'aml-subnet'
param privateEndpointsSubnetName string = 'pe-subnet'

param existingVnetResourceId string?
var existingVnetResourceIdParts = split(existingVnetResourceId ?? '', '/')
// var existingVnetResourceIdSubId = empty(existingVnetResourceId) ? '' : existingVnetResourceIdParts[2]
// var existingVnetResourceIdRgName = empty(existingVnetResourceId) ? '' : existingVnetResourceIdParts[4]
var existingVnetResourceIdName = empty(existingVnetResourceId) ? '' : existingVnetResourceIdParts[8]
var existingVnetResourceAppsSubnet = '${existingVnetResourceId}/subnets/${amlSubnetName}'
var existingVnetResourcePrivateEndpointsSubnet = '${existingVnetResourceId}/subnets/${privateEndpointsSubnetName}'

module defaultNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.2' = if (empty(existingVnetResourceId)) {
  name: 'default-network-security-group'
  params: {
    name: securityGroupName
    tags: tags
    location: location
    securityRules: []
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.2' = if (empty(existingVnetResourceId)) {
  name: 'virtual-network-${virtualNetworkName}'
  params: {
    addressPrefixes: ['10.0.0.0/26']
    name: virtualNetworkName
    location: location
    tags: tags
    subnets: [
      {
        name: amlSubnetName
        addressPrefix: '10.0.0.0/27'
        networkSecurityGroupResourceId: defaultNetworkSecurityGroup!.outputs.resourceId
      }
      {
        name: privateEndpointsSubnetName
        addressPrefix: '10.0.0.32/27'
        networkSecurityGroupResourceId: defaultNetworkSecurityGroup!.outputs.resourceId
      }
    ]
  }
}

output AZURE_VIRTUAL_NETWORK_ID string = virtualNetwork.?outputs.?resourceId ?? existingVnetResourceId!
output AZURE_VIRTUAL_NETWORK_NAME string = virtualNetwork.?outputs.?name ?? existingVnetResourceIdName!
output AZURE_VIRTUAL_NETWORK_AML_SUBNET_ID string = virtualNetwork.?outputs.?subnetResourceIds[0] ?? existingVnetResourceAppsSubnet
output AZURE_VIRTUAL_NETWORK_PRIVATE_ENDPOINTS_SUBNET_ID string = virtualNetwork.?outputs.?subnetResourceIds[1] ?? existingVnetResourcePrivateEndpointsSubnet
