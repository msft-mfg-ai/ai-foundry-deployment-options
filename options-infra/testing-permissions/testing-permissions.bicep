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
    peSubnetName: vnet.outputs.peSubnetName
    vnetResourceId: vnet.outputs.virtualNetworkId
    resourceToken: resourceToken
    aiServicesName: foundry.outputs.name
    aiAccountNameResourceGroupName: foundry.outputs.resourceGroupName
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
    managedIdentityId: '' // Use System Assigned Identity
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
    managedIdentityId: '' // Use System Assigned Identity
    name: 'ai-foundry-projects-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
    agentSubnetId: vnet.outputs.agentSubnetId // Use the first agent subnet
  }
}

module ai_foundry_projects_pe '../modules/networking/ai-pe-dns.bicep' = {
  name: 'ai-foundry-projects-pe-dns-deployment'
  params: {
    aiAccountName: foundry_projects.outputs.name
    aiAccountNameResourceGroup: foundry_projects.outputs.resourceGroupName
    peSubnetId: vnet.outputs.peSubnetId
    resourceToken: resourceToken
    existingDnsZones: ai_dependencies.outputs.DNSZones
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
      foundryName: foundry_projects.outputs.name
      location: location
      projectId: i
      aiDependencies: ai_dependencies.outputs.aiDependencies
      existingAiResourceId: foundry.outputs.id
      managedIdentityId: identities[i - 1].outputs.managedIdentityId
      appInsightsId: logAnalytics.outputs.applicationInsightsId
    }
  }
]

module projects_keys '../modules/ai/ai-project-with-caphost.bicep' = {
    name: 'ai-project-keys-with-caphost-${resourceToken}'
    params: {
      foundryName: foundry_projects.outputs.name
      location: location
      projectId: 4
      aiDependencies: ai_dependencies.outputs.aiDependencies
      existingAiResourceId: foundry.outputs.id
    }
  }

// ----------------------------------------------------------------------------------------------
// -- Role Assignments for Testing Permissions --------------------------------------------------
// ----------------------------------------------------------------------------------------------

module all_role_assignments '../modules/iam/all-role-assignments.bicep' = {
  name: 'all-role-assignments-deployment'
  params: {
    aiDependencies: ai_dependencies.outputs.aiDependencies
    foundryName: foundry_projects.outputs.name
    projectName: projects[0].outputs.projectName
    foundryResourceGroupName: foundry_projects.outputs.resourceGroupName
    foundrySubscriptionId: foundry_projects.outputs.subscriptionId

    aiServicesName: foundry.outputs.name
    aiServicesResourceGroupName: foundry.outputs.resourceGroupName
    aiServicesSubscriptionId: foundry.outputs.subscriptionId

    userPrincipalId: userPrincipalId
    roleAssignments: roleAssignments
  }
}
