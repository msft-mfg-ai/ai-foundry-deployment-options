@description('Azure region for the VPN subnet NSG.')
param location string

@description('Name of the VPN subnet NSG.')
param name string

@description('Address prefix of the VPN subnet.')
param vpnSubnetPrefix string

@description('All address prefixes assigned to the existing VNet.')
param azureVnetAddressPrefixes string[]

@description('Remote routed network prefix.')
param remoteNetworkCidr string

@description('WireGuard tunnel network prefix.')
param tunnelCidr string

@description('Deploy only the public WireGuard endpoint rule for point-to-site client access.')
param clientAccessOnly bool = false

@description('Tags applied to the NSG.')
param tags object = {}

var wireGuardRule = {
  name: 'AllowWireGuardInbound'
  properties: {
    priority: 3000
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Udp'
    sourceAddressPrefix: '*'
    sourcePortRange: '*'
    destinationAddressPrefix: vpnSubnetPrefix
    destinationPortRange: '51820'
    description: 'Allow the WireGuard UDP endpoint.'
  }
}

module vpnNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: '${name}-deployment'
  params: {
    name: name
    location: location
    tags: tags
    securityRules: clientAccessOnly
      ? [wireGuardRule]
      : [
          wireGuardRule
          {
            name: 'AllowRemoteNetworkInbound'
            properties: {
              priority: 3010
              direction: 'Inbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefix: remoteNetworkCidr
              sourcePortRange: '*'
              destinationAddressPrefixes: azureVnetAddressPrefixes
              destinationPortRange: '*'
              description: 'Allow forwarded traffic from the remote network into Azure.'
            }
          }
          {
            name: 'AllowAzureToRemoteInbound'
            properties: {
              priority: 3020
              direction: 'Inbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefixes: azureVnetAddressPrefixes
              sourcePortRange: '*'
              destinationAddressPrefix: remoteNetworkCidr
              destinationPortRange: '*'
              description: 'Allow Azure workload traffic entering the VPN appliance for the remote network.'
            }
          }
          {
            name: 'AllowAzureToTunnelInbound'
            properties: {
              priority: 3030
              direction: 'Inbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefixes: azureVnetAddressPrefixes
              sourcePortRange: '*'
              destinationAddressPrefix: tunnelCidr
              destinationPortRange: '*'
              description: 'Allow Azure workload traffic entering the VPN appliance for tunnel addresses.'
            }
          }
          {
            name: 'AllowVpnToRemoteOutbound'
            properties: {
              priority: 3000
              direction: 'Outbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefix: vpnSubnetPrefix
              sourcePortRange: '*'
              destinationAddressPrefix: remoteNetworkCidr
              destinationPortRange: '*'
              description: 'Allow the VPN appliance to reach the remote network.'
            }
          }
          {
            name: 'AllowRemoteToAzureOutbound'
            properties: {
              priority: 3010
              direction: 'Outbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefix: remoteNetworkCidr
              sourcePortRange: '*'
              destinationAddressPrefixes: azureVnetAddressPrefixes
              destinationPortRange: '*'
              description: 'Allow forwarded remote network traffic to Azure.'
            }
          }
          {
            name: 'AllowTunnelToAzureOutbound'
            properties: {
              priority: 3020
              direction: 'Outbound'
              access: 'Allow'
              protocol: '*'
              sourceAddressPrefix: tunnelCidr
              sourcePortRange: '*'
              destinationAddressPrefixes: azureVnetAddressPrefixes
              destinationPortRange: '*'
              description: 'Allow tunnel-address traffic to Azure.'
            }
          }
        ]
  }
}

output VPN_NSG_RESOURCE_ID string = vpnNetworkSecurityGroup.outputs.resourceId
output VPN_NSG_NAME string = vpnNetworkSecurityGroup.outputs.name
