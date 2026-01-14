param name string

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Azure region for the deployment')
param location string

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

param peeringResourceIds string[] = []

var defaultVnetAddressPrefix = '192.168.0.0/16'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: '${name}-virtual-network-deployment'
  params: {
    addressPrefixes: [vnetAddress]
    name: name
    location: location
    subnets: [
      {
        name: 'agent-snet'
        addressPrefix: agentSubnet
        delegation: 'Microsoft.app/environments'
      }
      {
        name: 'pe-snet'
        addressPrefix: peSubnet
        // No delegation for pe subnet
      }
    ]
    peerings: [
      for vnetId in peeringResourceIds: {
        remoteVirtualNetworkResourceId: vnetId
        remotePeeringEnabled: true
      }
    ]
  }
}

output virtualNetworkId string = virtualNetwork.outputs.resourceId
output peSubnetId string = virtualNetwork.outputs.subnetResourceIds[1]
output peSubnetName string = virtualNetwork.outputs.subnetNames[1]
output vnetName string = name
output resourceGroupName string = resourceGroup().name
output subscriptionId string = subscription().subscriptionId
