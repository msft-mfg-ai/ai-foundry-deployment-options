// This bicep files deploys simple foundry standard
// Foundry is deployed to one VNET, while all the dependencies are in another VNET
// with Private DNS resolver and VNET peering to enable name resolution
targetScope = 'resourceGroup'

param location string = resourceGroup().location


var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module hubCidr './modules/private-dns/private-dns-cidr.bicep' = {
  name: 'hubCidr'
  params: {
    vnetAddressPrefix: '172.16.0.0/24'
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet './modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    vnetAddressPrefix: '172.17.0.0/22'
    customDNS: privateDns.outputs.PRIVATE_DNS_IP
  }
}

module privateDns './modules/private-dns/private-dns.bicep' = {
  name: 'private-dns'
  params: {
    location: location
    hubVnetRanges: hubCidr.outputs.hubVnetRanges
  }
}

module ai_dependencies './modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    peSubnetName: privateDns.outputs.VIRTUAL_NETWORK_SUBNET_PE_NAME
    vnetResourceId: privateDns.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI serviced PE later
    aiAccountNameResourceGroupName: ''
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

module foundry './modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
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

module project1 './modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-1-with-caphost-${resourceToken}'
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

output FOUNDRY_PROJECT_CONNECTION_STRING string = project1.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
