// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param projectsCount int = 2
var tags = {
  'created-by': 'foundry-two-projects'
  'hidden-title': 'Foundry Standard - BYO Vnet'
}

import { apiType } from '../modules/apps/apps-private-link.bicep'

param apiServices apiType[] = [] // Array of external API definitions

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI services PE later
    aiAccountNameResourceGroupName: ''
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
    deployments: [
      {
        name: 'gpt-5.2'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5.2'
            version: '2025-12-11'
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

module project_identities '../modules/iam/identity.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-identity-${resourceToken}'
    params: {
      tags: tags
      location: location
      identityName: 'ai-project-${i}-identity-${resourceToken}'
    }
  }
]

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundryName: foundry.outputs.FOUNDRY_NAME
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      projectId: i
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: project_identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module mcp_apis '../modules/apps/apps-private-link.bicep' = {
  name: 'mcp-apis-private-link-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    externalApis: apiServices
  }
}

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = 'gpt-5.2'
output OPENAPI_URL string = first(filter(apiServices, api => api.name == 'weather-openapi')).?uri ?? ''
