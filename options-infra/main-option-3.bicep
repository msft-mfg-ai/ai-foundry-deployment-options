// This bicep files deploys two resource groups:
// 1. The main resource group for the AI Project and Foundry
// 2. The resource group for the AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// The AI Project is created in the main resource group, but it uses the dependencies
// from the second resource group and AI Foundry from a different subscription, included by existingAiResourceId
targetScope = 'subscription'

param location string
param applicationName string = 'my-app'
param app1Name string = '${applicationName}-1'
param app2Name string = '${applicationName}-2'
param deployApp2 bool = true // Set to false to deploy only one app

var app1ResourceGroupName = '${app1Name}-rg'
var app2ResourceGroupName = '${app2Name}-rg'
var foundryDependenciesResourceGroupName = '${applicationName}-foundry-dependencies-rg'

var tags = {
  purpose: 'AI Foundry testing option 3'
  option: '3'
  description: 'Two apps, one foundry dependencies RG, existing Foundry'
}

@description('The resource ID of the existing Ai resource - Azure Open AI, AI Services or AI Foundry. WARNING: existing AI Foundry must be in the same region as the location parameter.')
param existingAiResourceId string

@description('The Kind of AI Service, can be "AzureOpenAI" or "AIServices". For AI Foundry use AI Services. Its not recommended to use Azure OpenAI resource, since that only provided access to OpenAI models.')
@allowed([
  'AzureOpenAI'
  'AIServices'
])
param existingAiResourceKind string = 'AIServices' // Can be 'AzureOpenAI' or 'AIServices'

var resourceToken = toLower(uniqueString(subscription().subscriptionId, location))

resource app1ResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: app1ResourceGroupName
  location: location
  tags: tags
}
resource app2ResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = if(deployApp2) {
  name: app2ResourceGroupName
  location: location
  tags: tags
}
resource foundryDependenciesResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: foundryDependenciesResourceGroupName
  location: location
  tags: tags
}



// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet 'modules/networking/vnet.bicep' = {
  name: 'vnet'
  scope: foundryDependenciesResourceGroup
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    extraAgentSubnets: 2
  }
}

module ai_dependencies './modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  scope: foundryDependenciesResourceGroup
  params: {
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI serviced PE later
    aiAccountNameResourceGroupName: ''
  }
}

module app1 'modules/app/app-rg.bicep' = {
  name: 'app-${app1Name}'
  scope: app1ResourceGroup
  params: {
    location: location
    appName: app1Name
    agentSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.extraAgentSubnets[0].resourceId // Use the first agent subnet
    aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: existingAiResourceId
    existingAiResourceKind: existingAiResourceKind
  }
}

module app2 'modules/app/app-rg.bicep' = if(deployApp2) {
  name: 'app-${app2Name}'
  scope: app2ResourceGroup
  params: {
    location: location
    appName: app2Name
    agentSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.extraAgentSubnets[1].resourceId // Use the second agent subnet
    aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: existingAiResourceId
    existingAiResourceKind: existingAiResourceKind
  }
}

module ai1_private_endpoint 'modules/networking/ai-pe-dns.bicep' = {
  name: '${app1Name}-ai-private-endpoint'
  scope: foundryDependenciesResourceGroup
  params: {
    aiAccountName: app1.outputs.FOUNDRY_NAME
    aiAccountNameResourceGroup: app1ResourceGroup.name
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    resourceToken: resourceToken
    vnetId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
  }
}

module ai2_private_endpoint 'modules/networking/ai-pe-dns.bicep' = if(deployApp2) {
  name: '${app2Name}-ai-private-endpoint'
  scope: foundryDependenciesResourceGroup
  params: {
    aiAccountName: app2!.outputs.FOUNDRY_NAME
    aiAccountNameResourceGroup: app2ResourceGroup.name
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    resourceToken: resourceToken
    vnetId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
  }
}

output foundry1_connection_string string = app1.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output foundry2_connection_string string = deployApp2 ? app2!.outputs.FOUNDRY_PROJECT_CONNECTION_STRING : ''
