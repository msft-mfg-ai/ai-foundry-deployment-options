@description('Name of the existing virtual network.')
param vnetName string

@description('Name of the new VPN subnet.')
param vpnSubnetName string

@description('Address prefix of the new VPN subnet.')
param vpnSubnetPrefix string

@description('Resource ID of the VPN subnet NSG, which may be in another resource group.')
param networkSecurityGroupResourceId string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource vpnSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: vpnSubnetName
  properties: {
    addressPrefix: vpnSubnetPrefix
    networkSecurityGroup: {
      id: networkSecurityGroupResourceId
    }
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

output VPN_SUBNET_RESOURCE_ID string = vpnSubnet.id
