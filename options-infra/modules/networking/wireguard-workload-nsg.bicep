@description('Azure region for a newly created NSG.')
param location string

@description('Name of the NSG to create or extend.')
param nsgName string

@description('Create the NSG when the workload subnet does not already have one.')
param createNsg bool

@description('Address prefixes of workload subnets sharing this NSG.')
param workloadSubnetPrefixes string[]

@description('Remote routed network prefix.')
param remoteNetworkCidr string

@description('WireGuard tunnel network prefix.')
param tunnelCidr string

@minValue(100)
@maxValue(4056)
@description('First priority in a collision-free four-rule block.')
param priorityBase int

@description('Tags applied when an NSG is created.')
param tags object = {}

@description('Ownership identifier embedded in managed rule descriptions.')
param ownershipId string

var ownershipMarker = '[vpn-owner:${ownershipId}]'

resource newNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = if (createNsg) {
  name: nsgName
  location: location
  tags: tags
}

resource existingNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = if (!createNsg) {
  name: nsgName
}

var resolvedNsgName = createNsg ? newNsg.name : existingNsg.name
var resolvedNsgId = createNsg ? newNsg.id : existingNsg.id

resource allowNestedInbound 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  name: '${resolvedNsgName}/AllowNestedInbound'
  properties: {
    priority: priorityBase
    direction: 'Inbound'
    access: 'Allow'
    protocol: '*'
    sourcePortRange: '*'
    destinationPortRange: '*'
    sourceAddressPrefix: remoteNetworkCidr
    destinationAddressPrefixes: workloadSubnetPrefixes
    description: 'Allow routed traffic from the remote network. ${ownershipMarker}'
  }
}

resource allowTunnelInbound 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  name: '${resolvedNsgName}/AllowTunnelInbound'
  properties: {
    priority: priorityBase + 10
    direction: 'Inbound'
    access: 'Allow'
    protocol: '*'
    sourcePortRange: '*'
    destinationPortRange: '*'
    sourceAddressPrefix: tunnelCidr
    destinationAddressPrefixes: workloadSubnetPrefixes
    description: 'Allow traffic sourced from WireGuard tunnel addresses. ${ownershipMarker}'
  }
}

resource allowNestedOutbound 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  name: '${resolvedNsgName}/AllowNestedOutbound'
  properties: {
    priority: priorityBase + 20
    direction: 'Outbound'
    access: 'Allow'
    protocol: '*'
    sourcePortRange: '*'
    destinationPortRange: '*'
    sourceAddressPrefixes: workloadSubnetPrefixes
    destinationAddressPrefix: remoteNetworkCidr
    description: 'Allow routed traffic to the remote network. ${ownershipMarker}'
  }
}

resource allowTunnelOutbound 'Microsoft.Network/networkSecurityGroups/securityRules@2024-05-01' = {
  name: '${resolvedNsgName}/AllowTunnelOutbound'
  properties: {
    priority: priorityBase + 30
    direction: 'Outbound'
    access: 'Allow'
    protocol: '*'
    sourcePortRange: '*'
    destinationPortRange: '*'
    sourceAddressPrefixes: workloadSubnetPrefixes
    destinationAddressPrefix: tunnelCidr
    description: 'Allow traffic to WireGuard tunnel addresses. ${ownershipMarker}'
  }
}

output NSG_RESOURCE_ID string = resolvedNsgId
output NSG_NAME string = resolvedNsgName
