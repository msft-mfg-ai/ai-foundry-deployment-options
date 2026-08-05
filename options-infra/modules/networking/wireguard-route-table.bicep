@description('Azure region used when creating a route table.')
param location string

@description('Name of the route table to create or extend.')
param routeTableName string

@description('Create the route table when a workload subnet has no existing route table.')
param createRouteTable bool

@description('Remote routed network prefix.')
param remoteNetworkCidr string

@description('WireGuard tunnel network prefix.')
param tunnelCidr string

@description('Private IP address of the Azure WireGuard gateway.')
param gatewayPrivateIp string

@description('Tags applied when a route table is created.')
param tags object = {}

@description('Prefix for the two sample-owned route names.')
param routeNamePrefix string

resource newRouteTable 'Microsoft.Network/routeTables@2024-05-01' = if (createRouteTable) {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
  }
}

resource existingRouteTable 'Microsoft.Network/routeTables@2024-05-01' existing = if (!createRouteTable) {
  name: routeTableName
}

var resolvedRouteTableName = createRouteTable ? newRouteTable.name : existingRouteTable.name
var resolvedRouteTableId = createRouteTable ? newRouteTable.id : existingRouteTable.id

resource remoteNetworkRoute 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  name: '${resolvedRouteTableName}/${routeNamePrefix}-remote-network'
  properties: {
    addressPrefix: remoteNetworkCidr
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: gatewayPrivateIp
  }
}

resource tunnelNetworkRoute 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  name: '${resolvedRouteTableName}/${routeNamePrefix}-tunnel-network'
  properties: {
    addressPrefix: tunnelCidr
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: gatewayPrivateIp
  }
}

output ROUTE_TABLE_RESOURCE_ID string = resolvedRouteTableId
output ROUTE_TABLE_NAME string = resolvedRouteTableName
