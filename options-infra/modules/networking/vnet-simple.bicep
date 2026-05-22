/*
Virtual Network Module
This module deploys the core network infrastructure with security controls:

1. Address Space:
   - VNet CIDR: 172.16.0.0/16 OR 192.168.0.0/16
   - Agents Subnet: 172.16.0.0/24 OR 192.168.0.0/24
   - Private Endpoint Subnet: 172.16.101.0/24 OR 192.168.1.0/24

2. Security Features:
   - Network isolation
   - Subnet delegation
   - Private endpoint subnet
*/

@description('Azure region for the deployment')
param location string

param tags object = {}

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Private Endpoint subnet')
param peSubnetName string = 'pe-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

var is_vnet_address_prefix_valid = int(split(vnetAddress, '/')[1]) <= 26
  ? true
  : fail('VNet address prefix must be /26 or larger (e.g., /26, /25)')

// Regions where Azure AI Foundry Agents supports Class A (10.0.0.0/8) VNet address space.
// Other regions must use Class B (172.16.0.0/12) or Class C (192.168.0.0/16) ranges.
// West Europe is included as an additional supported region beyond the official Class A list.
var classASupportedLocations = [
  'australiaeast'
  'brazilsouth'
  'canadaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'germanywestcentral'
  'italynorth'
  'japaneast'
  'southafricanorth'
  'southcentralus'
  'southindia'
  'spaincentral'
  'swedencentral'
  'uaenorth'
  'uksouth'
  'westus'
  'westus3'
  'westeurope'
]
var isClassASupported = contains(classASupportedLocations, toLower(replace(location, ' ', '')))
var defaultVnetAddressPrefix = isClassASupported ? '10.0.0.0/26' : '192.168.0.0/26'

var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 27, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 27, 1) : peSubnetPrefix



module networkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'networkSecurityGroupDeployment'
  params: {
    name: 'agent-nsg'
    location: location
    tags: tags
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.9.0' = {
  name: '${vnetName}-virtual-network-deployment'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [vnetAddress]
    subnets: [
      {
        name: agentSubnetName
        addressPrefix: agentSubnet
        delegation: 'Microsoft.app/environments'
        networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
      }
      {
        name: peSubnetName
        addressPrefix: peSubnet
        networkSecurityGroupResourceId: networkSecurityGroup.outputs.resourceId
      }
    ]
  }
}

// Output variables
type SubnetInfoType = {
  name: string
  resourceId: string
}

type SubnetsType = {
  @description('The Agents Subnet information')
  agentSubnet: SubnetInfoType
  @description('The Private Endpoint Subnet information')
  peSubnet: SubnetInfoType
}

output VIRTUAL_NETWORK_SUBNETS SubnetsType = {
  agentSubnet: {
    name: agentSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${agentSubnetName}'
  }
  peSubnet: {
    name: peSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${peSubnetName}'
  }
}

output VIRTUAL_NETWORK_PREFIX_VALID bool = is_vnet_address_prefix_valid
output VIRTUAL_NETWORK_NAME string = virtualNetwork.name
output VIRTUAL_NETWORK_RESOURCE_ID string = virtualNetwork.outputs.resourceId
output VIRTUAL_NETWORK_RESOURCE_GROUP string = resourceGroup().name
output VIRTUAL_NETWORK_SUBSCRIPTION_ID string = subscription().subscriptionId
