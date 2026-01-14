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
param vnetName string = 'apim-vnet'

@description('The name of API Management v2 subnet')
param apimv2SubnetName string = 'apim-v2-subnet'

@description('The name of API Management v2 Premium subnet')
param apimv2PremiumSubnetName string = 'apim-v2-premium-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

param customDNS string = ''

@description('Address prefix for the APIM subnet')
param apimv2SubnetPrefix string = ''
@description('Address prefix for the APIM v2 Premium subnet')
param apimv2PremiumSubnetPrefix string = ''

param peeringResourceIds string[] = []

var is_vnet_address_prefix_valid = int(split(vnetAddress, '/')[1]) <= 23
  ? true
  : fail('VNet address prefix must be /23 or larger (e.g., /16, /20, /23)')

var defaultVnetAddressPrefix = '192.168.100.0/23'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var apimv2Subnet = empty(apimv2SubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : apimv2SubnetPrefix
var apimv2PremiumSubnet = empty(apimv2PremiumSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : apimv2PremiumSubnetPrefix

module apimv2SecurityGroup 'br/public:avm/res/network/network-security-group:0.5.2' = {
  name: 'apimv2SecurityGroupDeployment'
  params: {
    name: 'apim-v2-nsg-${location}'
    tags: tags
    location: location
    securityRules: [
      {
        name: 'AllowStorageOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
          description: 'Dependency on Azure Storage'
        }
      }
      {
        name: 'AllowKeyVaultOutbound'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureKeyVault'
          destinationPortRange: '443'
          description: 'Dependency on Azure Key Vault'
        }
      }
    ]
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: '${vnetName}-virtual-network-deployment'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [
      vnetAddress
    ]
    dnsServers: empty(customDNS)
      ? null
      : [
          customDNS
      ]
    subnets: [
      {
        name: apimv2SubnetName
        addressPrefix: apimv2Subnet
        networkSecurityGroupResourceId: apimv2SecurityGroup.outputs.resourceId
        delegation: 'Microsoft.Web/serverfarms'
      }
      {
        name: apimv2PremiumSubnetName
        addressPrefix: apimv2PremiumSubnet
        networkSecurityGroupResourceId: apimv2SecurityGroup.outputs.resourceId
        delegation: 'Microsoft.Web/hostingEnvironments'
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

// Output variables
type SubnetInfoType = {
  name: string
  resourceId: string
}
type SubnetsType = {
  @description('The API Management V2 SKUs Subnet information')
  apimv2Subnet: SubnetInfoType
  @description('The API Management V2 Premium SKUs Subnet information')
  apimv2PremiumSubnet: SubnetInfoType
}

output VIRTUAL_NETWORK_SUBNETS SubnetsType = {
  apimv2Subnet: {
    name: apimv2SubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${apimv2SubnetName}'
  }
  apimv2PremiumSubnet: {
    name: apimv2PremiumSubnetName
    resourceId: '${virtualNetwork.outputs.resourceId}/subnets/${apimv2PremiumSubnetName}'
  }
}

output VIRTUAL_NETWORK_PREFIX_VALID bool = is_vnet_address_prefix_valid
output VIRTUAL_NETWORK_NAME string = virtualNetwork.name
output VIRTUAL_NETWORK_RESOURCE_ID string = virtualNetwork.outputs.resourceId
output VIRTUAL_NETWORK_RESOURCE_GROUP string = resourceGroup().name
output VIRTUAL_NETWORK_SUBSCRIPTION_ID string = subscription().subscriptionId
