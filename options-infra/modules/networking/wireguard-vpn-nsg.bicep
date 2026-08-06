@description('Azure region for the VPN subnet NSG.')
param location string

@description('Name of the VPN subnet NSG.')
param name string

@description('Address prefix of the VPN subnet.')
param vpnSubnetPrefix string

@description('Tags applied to the NSG.')
param tags object = {}

module vpnNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: '${name}-deployment'
  params: {
    name: name
    location: location
    tags: tags
    securityRules: [
      {
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
    ]
  }
}

output VPN_NSG_RESOURCE_ID string = vpnNetworkSecurityGroup.outputs.resourceId
output VPN_NSG_NAME string = vpnNetworkSecurityGroup.outputs.name
