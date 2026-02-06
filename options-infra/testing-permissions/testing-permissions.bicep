import * as types from '../modules/types/types.bicep'

// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
// SimpleJoe
param userPrincipalId string = '6024be5e-3b6c-4bca-a621-26129c705bba' // The user principal ID to test permissions

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var roleAssignments types.FoundryRoleAssignmentsType = {
  foundry: [
    'Reader'
  ]
  project: [
    'Azure AI Project Manager'
  ]
  aiServices: [
    //'Reader'
    'Cognitive Services OpenAI User'
  ]
  storage: [
    // 'Storage Blob Data Contributor'
  ]
  aiSearch: [
    // 'Search Index Data Contributor'
    'Search Index Data Reader'
  ]
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    vnetAddressPrefix: '10.0.0.0/16'
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
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
  name: 'log-analytics'
  params: {
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
    location: location
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-with-models-${resourceToken}'
    location: location
    publicNetworkAccess: 'Disabled'
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

module foundry_projects '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-projects-deployment'
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-projects-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
  }
}

module ai_foundry_projects_pe '../modules/networking/ai-pe-dns.bicep' = {
  name: 'ai-foundry-projects-pe-dns-deployment'
  params: {
    aiAccountName: foundry_projects.outputs.FOUNDRY_NAME
    aiAccountNameResourceGroup: foundry_projects.outputs.FOUNDRY_RESOURCE_GROUP_NAME
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    resourceToken: resourceToken
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
  }
}

module identities '../modules/iam/identity.bicep' = [
  for i in range(1, 3): {
    name: 'ai-project-${i}-identity-${resourceToken}'
    params: {
      identityName: 'ai-project-${i}-identity-${resourceToken}'
      location: location
    }
  }
]

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, 3): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      foundryName: foundry_projects.outputs.FOUNDRY_NAME
      location: location
      projectId: i
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: foundry.outputs.FOUNDRY_RESOURCE_ID
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module projects_keys '../modules/ai/ai-project-with-caphost.bicep' = {
    name: 'ai-project-keys-with-caphost-${resourceToken}'
    params: {
      foundryName: foundry_projects.outputs.FOUNDRY_NAME
      location: location
      projectId: 4
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: foundry.outputs.FOUNDRY_RESOURCE_ID
    }
  }

// ----------------------------------------------------------------------------------------------
// -- Role Assignments for Testing Permissions --------------------------------------------------
// ----------------------------------------------------------------------------------------------

module all_role_assignments '../modules/iam/all-role-assignments.bicep' = {
  name: 'all-role-assignments-deployment'
  params: {
    aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
    foundryName: foundry_projects.outputs.FOUNDRY_NAME
    projectName: projects[0].outputs.FOUNDRY_PROJECT_NAME
    foundryResourceGroupName: foundry_projects.outputs.FOUNDRY_RESOURCE_GROUP_NAME
    foundrySubscriptionId: foundry_projects.outputs.FOUNDRY_SUBSCRIPTION_ID

    aiServicesName: foundry.outputs.FOUNDRY_NAME
    aiServicesResourceGroupName: foundry.outputs.FOUNDRY_RESOURCE_GROUP_NAME
    aiServicesSubscriptionId: foundry.outputs.FOUNDRY_SUBSCRIPTION_ID

    userPrincipalId: userPrincipalId
    roleAssignments: roleAssignments
  }
}
