// Deploys AI Foundry with two projects and a new VNet (BYO VNet injection).
// No storage, AI Search, or Cosmos DB dependencies are created.
// MCP tools are connected via private endpoints in the VNet.

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param projectsCount int = 1

var tags = {
  'created-by': 'foundry-byo-vnet'
  'hidden-title': 'Foundry Standard - BYO VNet (No BYOS Dependencies)'
}

import { apiType } from '../modules/apps/apps-private-link.bicep'
param apiServices apiType[] = []

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs its own delegated subnet; projects inside one Foundry share the agent subnet
module vnet '../modules/networking/vnet-simple.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
  }
}

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
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
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


module project_no_cap '../modules/ai/ai-project.bicep' = {
    name: 'ai-project-1-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundry.outputs.FOUNDRY_NAME
      project_name: 'ai-project-1-no-cap-${resourceToken}'
      project_description: 'AI Project 1 ${resourceToken} No Caphost, No Storage, No Search, No Cosmos'
      display_name: 'AI Project 1 No Caphost ${resourceToken}'
      managedIdentityResourceId: project_identities[0].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      // Account-level caphost is created automatically with VNet injection; only create once
      createAccountCapabilityHost: false
    }
  }

  module project_with_cap '../modules/ai/ai-project.bicep' = {
    name: 'ai-project-1-with-cap-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundry.outputs.FOUNDRY_NAME
      project_name: 'ai-project-1-with-cap-${resourceToken}'
      project_description: 'AI Project 1 ${resourceToken} With Caphost, No Storage, No Search, No Cosmos'
      display_name: 'AI Project 1 With Caphost ${resourceToken}'
      managedIdentityResourceId: project_identities[0].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      // Account-level caphost is created automatically with VNet injection; only create once
      createAccountCapabilityHost: false
    }
  }


module caphosts '../modules/ai/add-project-capability-host.bicep' =  {
    name: 'caphost-proj-with-cap-${resourceToken}'
    params: {
      accountName: foundry.outputs.FOUNDRY_NAME
      projectName: project_with_cap.outputs.FOUNDRY_PROJECT_NAME
    }
  }

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

module foundry_private_endpoint '../modules/networking/ai-pe-dns.bicep' = {
  name: 'foundry-private-endpoint-${resourceToken}'
  params: {
    tags: tags
    location: location
    aiAccountName: foundry.outputs.FOUNDRY_NAME
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    vnetId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
  }
}

output project_connection_strings string[] = [
  project_no_cap.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
  project_with_cap.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [
  project_no_cap.outputs.FOUNDRY_PROJECT_NAME
  project_with_cap.outputs.FOUNDRY_PROJECT_NAME
]
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_PROJECT_ENDPOINT_NO_CAP string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${project_no_cap.outputs.FOUNDRY_PROJECT_NAME}'
output AZURE_AI_PROJECT_ID_NO_CAP string = '${foundry.outputs.FOUNDRY_RESOURCE_ID}/projects/${project_no_cap.outputs.FOUNDRY_PROJECT_NAME}'
output FOUNDRY_PROJECT_ENDPOINT_WITH_CAP string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${project_with_cap.outputs.FOUNDRY_PROJECT_NAME}'
output AZURE_AI_PROJECT_ID_WITH_CAP string = '${foundry.outputs.FOUNDRY_RESOURCE_ID}/projects/${project_with_cap.outputs.FOUNDRY_PROJECT_NAME}'

output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = 'gpt-5.2'
output MCP_SERVER_URL string = first(filter(apiServices, api => api.name == 'weather-mcp')).?uri ?? ''
output SAMPLE_MCP_SERVER_URL string = first(filter(apiServices, api => api.name == 'sample-mcp')).?uri ?? ''
output OPENAPI_URL string = first(filter(apiServices, api => api.name == 'weather-openapi')).?uri ?? ''
