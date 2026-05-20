// Deploys AI Foundry with two projects into an existing (BYO) VNet.
// No storage, AI Search, or Cosmos DB dependencies are created.
// MCP tools are connected via private endpoints in the provided subnet.
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param projectsCount int = 2

var tags = {
  'created-by': 'foundry-byo-vnet'
  'hidden-title': 'Foundry Standard - BYO VNet (No Dependencies)'
}

import { apiType } from '../modules/apps/apps-private-link.bicep'
param apiServices apiType[] = []

@description('Resource ID of the existing VNet (used for DNS zone links and MCP private endpoints).')
param vnetResourceId string

@description('Resource ID of the existing agent subnet. Must be exclusively delegated to Microsoft.App/environments.')
param agentSubnetResourceId string

@description('Resource ID of the existing private endpoint subnet.')
param peSubnetResourceId string

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

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
    agentSubnetResourceId: agentSubnetResourceId
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
module projects '../modules/ai/ai-project.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundry.outputs.FOUNDRY_NAME
      project_name: 'ai-project-${i}-${resourceToken}'
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      managedIdentityResourceId: project_identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      // Account-level caphost is created automatically with VNet injection; only create once
      createAccountCapabilityHost: i == 1
    }
  }
]

// Create a project capability host for each project (no storage/search/cosmos connections)
@batchSize(1)
module caphosts '../modules/ai/add-project-capability-host.bicep' = [
  for i in range(1, projectsCount): {
    name: 'caphost-${i}-${resourceToken}'
    params: {
      accountName: foundry.outputs.FOUNDRY_NAME
      projectName: projects[i - 1].outputs.FOUNDRY_PROJECT_NAME
      cosmosDBConnection: projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_NAME_COSMOSDB
      azureStorageConnection: projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_NAME_STORAGE
      aiSearchConnection: projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI_SEARCH
      aiFoundryConnectionName: projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI
    }
  }
]

module mcp_apis '../modules/apps/apps-private-link.bicep' = {
  name: 'mcp-apis-private-link-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnetResourceId
    peSubnetResourceId: peSubnetResourceId
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
