// This bicep files deploys simple foundry standard
// ------------------
// Sample explores scenario where Foundry Agents Service is in one VNET, while all the dependencies
// are in another VNET, with Private DNS resolver and VNET peering to enable name resolution
targetScope = 'subscription'

param location string = 'westus'

var resourceToken = toLower(uniqueString(subscription().id, location))

/*
Ensure that the address spaces for the used VNET does not overlap with any existing 
networks in your Azure environment or reserved IP ranges like the following: 
* 169.254.0.0/16 - 169.254.0.0 to 169.254.255.255
* 172.30.0.0/16 - 172.30.0.0 to 172.30.255.255
* 172.31.0.0/16 - 172.31.0.0 to 172.31.255.255
* 192.0.2.0/24 - 192.0.2.0 to 192.0.2.255
* 0.0.0.0/8 - 0.0.0.0 to 0.255.255.255
* 127.0.0.0/8 - 127.0.0.0 to 127.255.255.255
* 100.100.0.0/17 - 100.100.0.0 to 100.100.127.255
* 100.100.192.0/19 - 100.100.192.0 to 100.100.223.255
* 100.100.224.0/19 - 100.100.224.0 to 100.100.255.255
* 100.64.0.0/11 - 100.64.0.0 to 100.95.255.255
This includes all address space(s) you have in your VNET if you have more than one,
and peered VNETs.
*/

var tags = {
  Environment: 'Non-Prod'
  'hidden-title': 'Test Foundry with separate DNS'
  Role: 'DeploymentValidation'
}

resource rg_central 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-central-${resourceToken}'
  location: location
  tags: tags
}

resource rg_foundry 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-foundry-${resourceToken}'
  location: location
  tags: tags
}

module hubCidr '../modules/private-dns/private-dns-cidr.bicep' = {
  scope: rg_central
  name: 'hubCidr'
  params: {
    vnetAddressPrefix: '100.32.0.0/25'
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  scope: rg_foundry
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    vnetAddressPrefix: '192.168.0.0/22'
  }
}

module privateDns '../modules/private-dns/private-dns.bicep' = {
  name: 'private-dns'
  scope: rg_central
  params: {
    location: location
    hubVnetRanges: hubCidr.outputs.hubVnetRanges
    // peeringResourceId: [vnet.outputs.virtualNetworkId]
    // vnetResourceIdsForLink: [vnet.outputs.virtualNetworkId]
  }
}

module dns_zones '../modules/networking/dns-zones.bicep' = {
  name: 'dns-zones-deployment'
  scope: rg_central
  params: {
    vnetResourceIds: [privateDns.outputs.VIRTUAL_NETWORK_RESOURCE_ID]
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  scope: rg_foundry
  params: {
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: foundry.outputs.FOUNDRY_NAME
    aiAccountNameResourceGroupName: foundry.outputs.FOUNDRY_RESOURCE_GROUP_NAME
  }
}
// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  scope: rg_foundry
  name: 'log-analytics'
  params: {
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
    location: location
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  scope: rg_foundry
  name: 'foundry-app-1-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    location: location
    publicNetworkAccess: 'Disabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
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

module foundry_pe '../modules/networking/ai-pe-dns.bicep' = {
  name: 'foundry-pe-dns'
  scope: rg_central
  params: {
    aiAccountName: foundry.outputs.FOUNDRY_NAME
    aiAccountNameResourceGroup: foundry.outputs.FOUNDRY_RESOURCE_GROUP_NAME
    aiAccountSubscriptionId: foundry.outputs.FOUNDRY_SUBSCRIPTION_ID
    peSubnetId: privateDns.outputs.VIRTUAL_NETWORK_SUBNET_PE_RESOURCE_ID
    vnetId: privateDns.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    existingDnsZones: dns_zones.outputs.DNS_ZONES
  }
}

module project1 '../modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-1-with-caphost-${resourceToken}'
  scope: rg_foundry
  params: {
    foundryName: foundry.outputs.FOUNDRY_NAME
    location: location
    projectId: 1
    aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.21.0' = {
  name: 'virtualMachineDeployment'
  scope: rg_central
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
            subnetResourceId: privateDns.outputs.VIRTUAL_NETWORK_SUBNET_PE_RESOURCE_ID
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
    vmSize: 'Standard_D2s_v3'
    // Non-required parameters
    disablePasswordAuthentication: true
    location: location
    publicKeys: [
      {
        keyData: loadTextContent('../../../../../.ssh/id_rsa.pub')
        path: '/home/localAdminUser/.ssh/authorized_keys'
      }
    ]
  }
}

output foundry1_connection_string string = project1.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
