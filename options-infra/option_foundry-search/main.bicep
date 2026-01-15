// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param principalId string?
param projectsCount int = 3

var tags = {
  'created-by': 'option-foundry-search'
  'hidden-title': 'Foundry - AI Search'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
    extraAgentSubnets: 1
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
    aiServicesName: '' // create AI serviced PE later
    aiAccountNameResourceGroupName: ''
  }
}

module searchServicePublicNoPe 'br/public:avm/res/search/search-service:0.12.0' = {
  params: {
    // Required parameters
    name: 'ai-search-public-no-pe-${resourceToken}'
    // Non-required parameters
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    computeType: 'Default'
    dataExfiltrationProtections: [
      'All'
    ]
    disableLocalAuth: false
    hostingMode: 'Default'
    location: location
    managedIdentities: {
      systemAssigned: true
      // userAssignedResourceIds: [
      //   '<managedIdentityResourceId>'
      // ]
    }
    networkRuleSet: {
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Enabled'
    partitionCount: 1
    // replicaCount: 3
    roleAssignments: union(
      map(identities, id => {
        principalId: id.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Contributor'
      }),
      map(identities, id => {
        principalId: id.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Service Contributor'
      }),
      empty(principalId)
        ? []
        : [
            {
              principalId: principalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Service Contributor'
            }
            {
              principalId: principalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Index Data Contributor'
            }
          ]
    )
    semanticSearch: 'standard'
    sku: 'standard'
    tags: union(tags, {
      'hidden-title': 'AI Search Public PE'
    })
  }
}

module searchServicePublicPe 'br/public:avm/res/search/search-service:0.12.0' = {
  params: {
    // Required parameters
    name: 'ai-search-public-pe-${resourceToken}'
    // Non-required parameters
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    computeType: 'Default'
    dataExfiltrationProtections: [
      'All'
    ]
    disableLocalAuth: false
    hostingMode: 'Default'
    publicNetworkAccess: 'Enabled'
    location: location
    managedIdentities: {
      systemAssigned: true
      // userAssignedResourceIds: [
      //   '<managedIdentityResourceId>'
      // ]
    }
    networkRuleSet: {
      bypass: 'AzureServices'
    }
    privateEndpoints: [
      {
        subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
        tags: tags
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.search.windows.net'].resourceId
            }
          ]
        }
      }
    ]
    partitionCount: 1
    // replicaCount: 3
    roleAssignments: union(
      map(identities, id => {
        principalId: id.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Index Data Contributor'
      }),
      map(identities, id => {
        principalId: id.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Search Service Contributor'
      }),
      empty(principalId)
        ? []
        : [
            {
              principalId: principalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Service Contributor'
            }
            {
              principalId: principalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Index Data Contributor'
            }
          ]
    )
    semanticSearch: 'standard'
    sku: 'standard'
    tags: union(tags, {
      'hidden-title': 'AI Search Public PE'
    })
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

var foundryName = 'ai-foundry-${resourceToken}'

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: foundryName
    disableLocalAuth: false // enable local auth because AI Foundry needs it
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

module identities '../modules/iam/identity.bicep' = [
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
      foundryName: foundryName
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      projectId: i
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
    dependsOn: [foundry]
  }
]

module userAiSearchRoleAssignments '../modules/iam/ai-search-role-assignments.bicep' = if (!empty(principalId)) {
  name: 'user-ai-search-role-assignments-deployment'
  params: {
    aiSearchName: ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name
    principalId: principalId!
    principalType: 'User'
  }
}

resource foundryExisting 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryName
}

resource acount_connection_azureai_search_public_no_pe 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' =  {
  name: '${searchServicePublicNoPe.name}-connection'
  parent: foundryExisting
  properties: {
    category: 'CognitiveSearch'
    target: searchServicePublicNoPe.outputs.endpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServicePublicNoPe.outputs.resourceId
      location: searchServicePublicNoPe.outputs.location
    }
  }
}

resource acount_connection_azureai_search_public_pe 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' =  {
  name: '${searchServicePublicPe.name}-connection'
  parent: foundryExisting
  properties: {
    category: 'CognitiveSearch'
    target: searchServicePublicPe.outputs.endpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServicePublicPe.outputs.resourceId
      location: searchServicePublicPe.outputs.location
    }
  }
}

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output FOUNDRY_NAME string = foundryName
output AI_SEARCH_SERVICE_PUBLIC_NO_PE string = searchServicePublicNoPe.outputs.endpoint
output AI_SEARCH_SERVICE_PUBLIC_PE string = searchServicePublicPe.outputs.endpoint
output AI_SEARCH_PE string = 'https://${ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name}.search.windows.net'
output AI_SEARCH_PE_NAME string = ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name
