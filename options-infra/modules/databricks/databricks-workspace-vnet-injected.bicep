@description('Azure region for the Databricks workspace and networking resources.')
param location string = resourceGroup().location

@description('Resource tags.')
param tags object = {}

@description('Azure Databricks workspace name.')
param workspaceName string

@description('Existing virtual network name.')
param vnetName string

@description('Existing virtual network resource ID.')
param vnetResourceId string

@description('Subnet resource ID for the managed-storage private endpoints.')
param privateEndpointSubnetId string

@description('Existing private DNS zone resource ID for Azure Blob Storage.')
param blobPrivateDnsZoneId string

@description('CIDR for the Databricks host (public) subnet.')
param publicSubnetPrefix string

@description('CIDR for the Databricks container (private) subnet.')
param privateSubnetPrefix string

@description('Databricks host subnet name.')
param publicSubnetName string = 'databricks-public-subnet'

@description('Databricks container subnet name.')
param privateSubnetName string = 'databricks-private-subnet'

@description('Enable Secure Cluster Connectivity so cluster nodes do not receive public IP addresses.')
param enableNoPublicIp bool = true

@allowed([
  'trial'
  'standard'
  'premium'
])
@description('Azure Databricks workspace SKU.')
param pricingTier string = 'premium'

var managedResourceGroupName = take(
  'databricks-rg-${workspaceName}-${uniqueString(workspaceName, resourceGroup().id)}',
  90
)
var managedResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', managedResourceGroupName)
var managedStorageName = 'dbx${uniqueString(resourceGroup().id, workspaceName)}'
var managedStorageContainerName = 'unity-catalog'
var accessConnectorName = take('ac-${workspaceName}-${uniqueString(resourceGroup().id)}', 64)

resource databricksNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${workspaceName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-worker-inbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-worker-outbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-databricks-webapp'
        properties: {
          priority: 101
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '443'
            '3306'
            '8443-8451'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'AzureDatabricks'
        }
      }
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-sql'
        properties: {
          priority: 102
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3306'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Sql'
        }
      }
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-storage'
        properties: {
          priority: 103
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'Storage'
        }
      }
      {
        name: 'Microsoft.Databricks-workspaces_UseOnly_databricks-worker-to-eventhub'
        properties: {
          priority: 104
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '9093'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'EventHub'
        }
      }
    ]
  }
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-nat-${workspaceName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${workspaceName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource publicSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: publicSubnetName
  properties: {
    addressPrefix: publicSubnetPrefix
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: databricksNsg.id
    }
    natGateway: {
      id: natGateway.id
    }
    delegations: [
      {
        name: 'databricks-workspace'
        properties: {
          serviceName: 'Microsoft.Databricks/workspaces'
        }
      }
    ]
  }
}

resource privateSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: privateSubnetName
  properties: {
    addressPrefix: privateSubnetPrefix
    defaultOutboundAccess: false
    networkSecurityGroup: {
      id: databricksNsg.id
    }
    natGateway: {
      id: natGateway.id
    }
    delegations: [
      {
        name: 'databricks-workspace'
        properties: {
          serviceName: 'Microsoft.Databricks/workspaces'
        }
      }
    ]
  }
}

resource workspace 'Microsoft.Databricks/workspaces@2026-01-01' = {
  name: workspaceName
  location: location
  tags: tags
  sku: {
    name: pricingTier
  }
  properties: {
    computeMode: 'Hybrid'
    managedResourceGroupId: managedResourceGroupId
    publicNetworkAccess: 'Enabled'
    requiredNsgRules: 'AllRules'
    parameters: {
      customVirtualNetworkId: {
        value: vnetResourceId
      }
      customPublicSubnetName: {
        value: publicSubnet.name
      }
      customPrivateSubnetName: {
        value: privateSubnet.name
      }
      enableNoPublicIp: {
        value: enableNoPublicIp
      }
    }
  }
}

resource accessConnector 'Microsoft.Databricks/accessConnectors@2024-05-01' = {
  name: accessConnectorName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource managedStorage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: managedStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: managedStorage
  name: 'default'
}

resource managedStorageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: managedStorageContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource dfsPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.dfs.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource dfsPrivateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dfsPrivateDnsZone
  name: '${workspaceName}-vnet-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${managedStorage.name}-blob'
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: 'nic-${managedStorage.name}-blob'
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: managedStorage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource blobPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

resource dfsPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${managedStorage.name}-dfs'
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: 'nic-${managedStorage.name}-dfs'
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'dfs'
        properties: {
          privateLinkServiceId: managedStorage.id
          groupIds: [
            'dfs'
          ]
        }
      }
    ]
  }
  dependsOn: [
    blobPrivateDnsGroup
  ]
}

resource dfsPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: dfsPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'dfs'
        properties: {
          privateDnsZoneId: dfsPrivateDnsZone.id
        }
      }
    ]
  }
}

resource accessConnectorStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedStorage.id, accessConnector.id, 'Storage Blob Data Contributor')
  scope: managedStorage
  properties: {
    principalId: accessConnector.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

output WORKSPACE_ID string = workspace.id
output WORKSPACE_NUMERIC_ID string = workspace.properties.workspaceId
output WORKSPACE_NAME string = workspace.name
output WORKSPACE_URL string = 'https://${workspace.properties.workspaceUrl}'
output GENIE_ONE_MCP_URL string = 'https://${workspace.properties.workspaceUrl}/api/2.0/mcp/genie'
output NAT_PUBLIC_IP string = natPublicIp.properties.ipAddress
output ACCESS_CONNECTOR_ID string = accessConnector.id
output MANAGED_STORAGE_URL string = 'abfss://${managedStorageContainer.name}@${managedStorage.name}.dfs.${environment().suffixes.storage}'
