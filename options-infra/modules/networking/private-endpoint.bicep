@description('The name of the private endpoint to create')
param privateEndpointName string

@description('The region where the private endpoint will be created')
param location string = resourceGroup().location

@description('The ID of the subnet where the private endpoint will be created')
param subnetId string

@description('The ID of the resource to which the private endpoint will be connected')
param targetResourceId string

@description('An array of group IDs of the service type that they private endpoint will be connect to')
param groupIds array

@description('The tags to associate with the private endpoint')
param tags object = {}

@export()
type zoneConfigType = {
  name: string
  privateDnsZoneId: string
}

param zoneConfigs zoneConfigType[] = []

var nicName = '${privateEndpointName}-nic'

resource pe 'Microsoft.Network/privateEndpoints@2023-06-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: nicName
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-06-01' = if (length(zoneConfigs) > 0) {
  name: '${privateEndpointName}-dns-group'
  parent: pe
  properties: {
    privateDnsZoneConfigs: [for z in zoneConfigs: {
      name: z.name
      properties: {
        privateDnsZoneId: z.privateDnsZoneId
      }
    }]
  }
}

resource peNic 'Microsoft.Network/networkInterfaces@2024-05-01' existing = {
  name: nicName
  dependsOn: [
    pe
  ]
}

output privateEndpointId string = pe.id
output privateEndpointName string = pe.name
output privateIpAddress string = peNic.properties.ipConfigurations[0].properties.privateIPAddress
