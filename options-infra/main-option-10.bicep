// This bicep files deploys simple foundry standard with dependencies in a different region across 3 subscriptions
// Foundry and dependencies - Sub 1
// Private endpoints - Sub 2
// DNS - Sub 3
// App VNET with peering to Foundry VNET
// ------------------
// Create main-option-10.local.bicepparam based on main-option-10.bicepparam
//
// Deploy using:
// az deployment mg create --management-group-id <name>-management-group --template-file main-option-10.bicep --parameters main-option-10.local.bicepparam -l westus
targetScope = 'managementGroup'

param foundryLocation string = 'swedencentral'
param foundrySubscriptionId string
param foundryResourceGroupName string = 'rg-ai-foundry'

param appLocation string = 'westeurope'
param appSubscriptionId string
param appResourceGroupName string = 'rg-ai-apps'

param dnsLocation string = appLocation
param dnsSubscriptionId string = appSubscriptionId
param dnsResourceGroupName string = 'rg-private-dns'

var resourceToken = toLower(uniqueString(managementGroup().id, foundryLocation))

var foundry_rg_id = '/subscriptions/${foundrySubscriptionId}/resourceGroups/${foundryResourceGroupName}'
var app_rg_id = '/subscriptions/${appSubscriptionId}/resourceGroups/${appResourceGroupName}'
var dns_rg_id = '/subscriptions/${dnsSubscriptionId}/resourceGroups/${dnsResourceGroupName}'

var tags = {
  'hidden-link:${foundry_rg_id}': 'Resource'
  'hidden-link:${app_rg_id}': 'Resource'
  'hidden-link:${dns_rg_id}': 'Resource'
  'hidden-title': 'Foundry DNS testing'
}

// first create resource groups for everything
module foundry_rg './modules/basic/resource-group.bicep' = {
  name: 'foundry-rg-deployment'
  scope: subscription(foundrySubscriptionId)
  params: {
    resourceGroupName: foundryResourceGroupName
    location: foundryLocation
    tags: tags
  }
}

module app_rg './modules/basic/resource-group.bicep' = {
  name: 'app-rg-deployment'
  scope: subscription(appSubscriptionId)
  params: {
    resourceGroupName: appResourceGroupName
    location: appLocation
    tags: tags
  }
}

module dns_rg './modules/basic/resource-group.bicep' = {
  name: 'dns-rg-deployment'
  scope: subscription(dnsSubscriptionId)
  params: {
    resourceGroupName: dnsResourceGroupName
    location: dnsLocation
    tags: tags
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module foundry_vnet './modules/networking/vnet.bicep' = {
  name: 'foundry_vnet'
  scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
  params: {
    vnetName: 'foundry-vnet-${resourceToken}'
    location: foundryLocation
    vnetAddressPrefix: '172.17.0.0/22'
  }
  dependsOn: [foundry_rg]
}

module app_vnet './modules/networking/vnet-with-peering.bicep' = {
  name: 'app-vnet-deployment'
  scope: resourceGroup(appSubscriptionId, appResourceGroupName)
  params: {
    name: 'app-vnet'
    location: appLocation
    vnetAddressPrefix: '172.18.0.0/22'
    peeringResourceIds: [foundry_vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID]
  }
  dependsOn: [app_rg]
}

module dns_zones './modules/networking/dns-zones.bicep' = {
  name: 'dns-zones-deployment'
  scope: resourceGroup(dnsSubscriptionId, dnsResourceGroupName)
  params: {
    vnetResourceIds: [
      app_vnet.outputs.virtualNetworkId
      foundry_vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    ]
  }
  dependsOn: [dns_rg]
}

module ai_dependencies './modules/ai-dependencies/standard-dependent-resources.bicep' = {
  scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
  params: {
    location: foundryLocation
    azureStorageName: 'projstorage${resourceToken}'
    aiSearchName: 'project-search-${resourceToken}'
    cosmosDBName: 'project-cosmosdb-${resourceToken}'
    // AI Search Service parameters

    // Storage Account

    // Cosmos DB Account
  }
}

module privateEndpointAndDNS './modules/networking/private-endpoint-and-dns.bicep' = {
  name: 'private-endpoints-and-dns'
  scope: resourceGroup(appSubscriptionId, appResourceGroupName)
  params: {
    // provide existing DNS zones
    #disable-next-line what-if-short-circuiting
    existingDnsZones: dns_zones.outputs.DNS_ZONES
    #disable-next-line what-if-short-circuiting
    aiAccountName: foundry.outputs.FOUNDRY_NAME
    #disable-next-line what-if-short-circuiting
    aiSearchName: ai_dependencies.outputs.AI_SEARCH_NAME // AI Search to secure
    #disable-next-line what-if-short-circuiting
    storageName: ai_dependencies.outputs.STORAGE_NAME // Storage to secure
    #disable-next-line what-if-short-circuiting
    cosmosDBName: ai_dependencies.outputs.COSMOS_DB_NAME
    #disable-next-line what-if-short-circuiting
    vnetName: app_vnet.outputs.vnetName
    #disable-next-line what-if-short-circuiting
    peSubnetName: app_vnet.outputs.peSubnetName
    #disable-next-line what-if-short-circuiting
    suffix: resourceToken // Unique identifier
    #disable-next-line what-if-short-circuiting
    vnetResourceGroupName: app_vnet.outputs.resourceGroupName // Resource Group for the VNet
    #disable-next-line what-if-short-circuiting
    vnetSubscriptionId: app_vnet.outputs.subscriptionId // Subscription ID for the VNet
    #disable-next-line what-if-short-circuiting
    cosmosDBSubscriptionId: ai_dependencies.outputs.COSMOS_DB_SUBSCRIPTION_ID // Subscription ID for Cosmos DB
    #disable-next-line what-if-short-circuiting
    cosmosDBResourceGroupName: ai_dependencies.outputs.COSMOS_DB_RESOURCE_GROUP_NAME // Resource Group for Cosmos DB
    #disable-next-line what-if-short-circuiting
    aiSearchSubscriptionId: ai_dependencies.outputs.AI_SEARCH_SUBSCRIPTION_ID // Subscription ID for AI Search Service
    #disable-next-line what-if-short-circuiting
    aiSearchResourceGroupName: ai_dependencies.outputs.AI_SEARCH_RESOURCE_GROUP_NAME // Resource Group for AI Search Service
    #disable-next-line what-if-short-circuiting
    storageAccountResourceGroupName: ai_dependencies.outputs.STORAGE_RESOURCE_GROUP_NAME // Resource Group for Storage Account
    #disable-next-line what-if-short-circuiting
    storageAccountSubscriptionId: ai_dependencies.outputs.STORAGE_SUBSCRIPTION_ID // Subscription ID for Storage Account
    #disable-next-line what-if-short-circuiting
    aiAccountNameResourceGroup: foundry.outputs.FOUNDRY_RESOURCE_GROUP_NAME
    #disable-next-line what-if-short-circuiting
    aiAccountSubscriptionId: foundry.outputs.FOUNDRY_SUBSCRIPTION_ID
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics './modules/monitor/loganalytics.bicep' = {
  scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
  name: 'log-analytics'
  params: {
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

module foundry './modules/ai/ai-foundry.bicep' = {
  scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
  name: 'ai-foundry-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: foundry_vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4.1-mini'
            version: '2025-04-14'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
    ]
  }
}

module project1 './modules/ai/ai-project-with-caphost.bicep' = {
  scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
  name: 'ai-project-1-with-caphost-${resourceToken}'
  params: {
    foundryName: foundry.outputs.FOUNDRY_NAME
    location: foundryLocation
    projectId: 1
    aiDependencies: ai_dependencies.outputs.AI_DEPENDENCIES
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.21.0' = if (false) {
  name: 'virtualMachineDeployment'
  scope: resourceGroup(appSubscriptionId, appResourceGroupName)
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
            subnetResourceId: app_vnet.outputs.peSubnetId
            pipConfiguration: {
              availabilityZones: []
              skuName: 'Basic'
              skuTier: 'Regional'
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
    vmSize: 'Standard_D2als_v6'
    // Non-required parameters
    disablePasswordAuthentication: true
    location: appLocation
    publicKeys: [
      {
        keyData: loadTextContent('../../../../.ssh/id_rsa.pub')
        path: '/home/localAdminUser/.ssh/authorized_keys'
      }
    ]
  }
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = project1.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
