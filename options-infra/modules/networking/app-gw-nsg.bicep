param tags object = {}
param location string = resourceGroup().location
param name string = 'appgw-nsg'

module appGwNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.2' = {
  name: 'appGwNetworkSecurityGroup-deployment'
  params: {
    name: name
    tags: tags
    location: location
    securityRules: [
      // Required: Allow Application Gateway V2 infrastructure communication
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
          description: 'Required for Application Gateway V2 infrastructure communication'
        }
      }
      // Required: Allow Azure Load Balancer health probes
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Required for Azure Load Balancer health probes'
        }
      }
      // Allow HTTPS traffic from internet (for public-facing App Gateway)
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
          description: 'Allow HTTPS traffic'
        }
      }
      // Allow HTTP traffic (optional - for redirect to HTTPS)
      {
        name: 'AllowHttpInbound'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
          description: 'Allow HTTP traffic (for HTTPS redirect)'
        }
      }
    ]
  }
}

@description('The resource ID of the NSG')
output networkSecurityGroupResourceId string = appGwNetworkSecurityGroup.outputs.resourceId

@description('The name of the NSG')
output nsgName string = appGwNetworkSecurityGroup.outputs.name
