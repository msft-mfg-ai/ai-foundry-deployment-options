// Deployment using official AVM module for AI Foundry https://github.com/Azure/bicep-avm-ptn-aiml-landing-zone
targetScope = 'resourceGroup'

param location string = resourceGroup().location

param user_principal_id string = ''

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet './modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    vnetAddressPrefix: '172.17.0.0/22'
  }
}

module dns_zones './modules/networking/dns-zones.bicep' = {
  name: 'dns-zones-deployment'
  params: {
    vnetResourceIds: [
      vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    ]
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics './modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
    location: location
  }
}

// regions that do not support Cosmos DB in EUAP or have limited capacity
var canaryRegions = ['eastus2euap', 'centraluseuap']
// TODO: fix if capacity issue is resolved
var lowCapacityRegions = ['eastus', 'northeurope', 'westeurope', 'southcentralus']
var cosmosDbRegion = contains(canaryRegions, location) ? 'westus' : location
var isLowCapacityRegion = contains(lowCapacityRegions, location)
resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if (isLowCapacityRegion) {
  name: 'cosmosdb-${resourceToken}'
  location: cosmosDbRegion
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    publicNetworkAccess: 'Disabled'
    enableFreeTier: false
    locations: [
      {
        locationName: contains(lowCapacityRegions, location) ? 'eastus2' : location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    databaseAccountOfferType: 'Standard'
  }
}

module cosmosPE 'br/public:avm/res/network/private-endpoint:0.11.1' = {
  name: '${cosmosDB.name}-pe-deployment'
  params: {
    // Required parameters
    name: '${cosmosDB.name}-pe'
    location: location
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    // Non-required parameters
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          privateDnsZoneResourceId: dns_zones.outputs.COSMOS_DB_PRIVATE_DNS_ZONE_RESOURCE_ID
        }
      ]
    }
    privateLinkServiceConnections: [
      {
        name: cosmosDB.name
        properties: {
          groupIds: [
            'Sql'
          ]
          privateLinkServiceId: cosmosDB.id
        }
      }
    ]
  }
}

// https://github.com/Azure/bicep-avm-ptn-aiml-landing-zone
// https://github.com/Azure/bicep-registry-modules/tree/main/avm/ptn/ai-ml/ai-foundry
module aiFoundry 'br/public:avm/ptn/ai-ml/ai-foundry:0.6.0' = {
  name: 'aiFoundryDeployment'
  dependsOn: [cosmosPE]
  params: {
    // Required parameters
    baseName: 'foundry'
    // Non-required parameters
    #disable-next-line what-if-short-circuiting
    aiFoundryConfiguration: {
      allowProjectManagement: true
      createCapabilityHosts: true
      location: location
      networking: {
        agentServiceSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
        aiServicesPrivateDnsZoneResourceId: dns_zones.outputs.AI_SERVICES_PRIVATE_DNS_ZONE_RESOURCE_ID
        cognitiveServicesPrivateDnsZoneResourceId: dns_zones.outputs.COGNITIVE_SERVICES_PRIVATE_DNS_ZONE_RESOURCE_ID
        openAiPrivateDnsZoneResourceId: dns_zones.outputs.OPENAI_PRIVATE_DNS_ZONE_RESOURCE_ID
      }
      project: {
        name: 'ai-project-1'
        displayName: 'AI Project 1'
        desc: 'This is a description for AI Project 1'
      }
      roleAssignments: empty(user_principal_id)
        ? []
        : [
            {
              principalId: user_principal_id
              principalType: 'User'
              roleDefinitionIdOrName: 'Azure AI User'
            }
          ]
    }
    aiModelDeployments: [
      {
        model: {
          format: 'OpenAI'
          name: 'gpt-4o'
          version: '2024-11-20'
        }
        name: 'gpt-4o'
        sku: {
          capacity: 1
          name: 'Standard'
        }
      }
    ]
    aiSearchConfiguration: {
      // name: '<name>'
      privateDnsZoneResourceId: dns_zones.outputs.AI_SEARCH_PRIVATE_DNS_ZONE_RESOURCE_ID
      // roleAssignments: [
      //   {
      //     principalId: '<principalId>'
      //     principalType: 'ServicePrincipal'
      //     roleDefinitionIdOrName: 'Search Index Data Contributor'
      //   }
      // ]
    }
    cosmosDbConfiguration: {
      existingResourceId: isLowCapacityRegion ? cosmosDB.id : ''
      // name: '<name>'
      privateDnsZoneResourceId: dns_zones.outputs.COSMOS_DB_PRIVATE_DNS_ZONE_RESOURCE_ID
      // roleAssignments: [
      //   {
      //     principalId: '<principalId>'
      //     principalType: 'ServicePrincipal'
      //     roleDefinitionIdOrName: 'Cosmos DB Account Reader Role'
      //   }
      // ]
    }
    includeAssociatedResources: true
    keyVaultConfiguration: {
      // name: '<name>'
      privateDnsZoneResourceId: dns_zones.outputs.KEY_VAULT_PRIVATE_DNS_ZONE_RESOURCE_ID
      // roleAssignments: [
      //   {
      //     principalId: '<principalId>'
      //     principalType: 'ServicePrincipal'
      //     roleDefinitionIdOrName: 'Key Vault Secrets User'
      //   }
      // ]
    }
    location: location
    lock: {
      kind: 'CanNotDelete'
      name: 'Please do not delete'
    }
    privateEndpointSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    storageAccountConfiguration: {
      blobPrivateDnsZoneResourceId: dns_zones.outputs.STORAGE_PRIVATE_DNS_ZONE_RESOURCE_ID
      // name: '<name>'
      // roleAssignments: [
      //   {
      //     principalId: '<principalId>'
      //     principalType: 'ServicePrincipal'
      //     roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      //   }
      // ]
    }
    tags: {
      Environment: 'Example'
      'hidden-title': 'Foundry from AVM Module'
      Role: 'DeploymentValidation'
      SecurityControl: 'Ignore'
    }
  }
}

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.21.0' = if (false) {
  name: 'virtualMachineDeployment'
  params: {
    // Required parameters
    adminUsername: 'localAdminUser'
    availabilityZone: -1
    encryptionAtHost: false
    imageReference: {
      offer: '0001-com-ubuntu-server-jammy'
      publisher: 'Canonical'
      sku: '22_04-lts-gen2'
      version: 'latest'
    }
    name: 'testing-vm-pka'
    managedIdentities: {
      systemAssigned: true
    }
    nicConfigurations: [
      {
        deleteOption: 'Delete'
        nicSuffix: '-nic-01'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
            pipConfiguration: {
              publicIpNameSuffix: '-pip-01'
            }
          }
        ]
      }
    ]
    osDisk: {
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      diskSizeGB: 32
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    osType: 'Linux'
    vmSize: 'Standard_D2s_v3'
    // Non-required parameters
    disablePasswordAuthentication: true
    location: location
    publicKeys: [
      {
        keyData: loadTextContent('../../../../.ssh/id_rsa.pub')
        path: '/home/localAdminUser/.ssh/authorized_keys'
      }
    ]
  }
}

output FOUNDRY_PROJECT_NAME string = aiFoundry.outputs.aiProjectName
