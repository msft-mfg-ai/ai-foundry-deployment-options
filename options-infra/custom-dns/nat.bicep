param location string
param name string
param tags object = {}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${name}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  tags: tags
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${name}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
  tags: tags
}

output NAT_GATEWAY_RESOURCE_ID string = natGateway.id
