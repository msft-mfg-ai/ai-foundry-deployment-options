// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param principalId string?
param projectsCount int = 1

var tags = {
  'created-by': 'foundry-rag-search'
  'hidden-title': 'Foundry - HR RAG'
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
      // 'All' // this blocks skillsets
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
    sharedPrivateLinkResources: [
      {
        name: 'ai-foundry-connection-${resourceToken}'
        groupId: 'cognitiveservices_account'
        privateLinkResourceId: foundry.outputs.FOUNDRY_RESOURCE_ID
        requestMessage: 'Please approve the connection.'
      }
      {
        name: 'blob-connection-${resourceToken}'
        groupId: 'blob'
        privateLinkResourceId: ai_dependencies.outputs.AI_DEPENDECIES.azureStorage.resourceId
        requestMessage: 'Please approve the connection.'
      }
    ]
    semanticSearch: 'free'
    sku: 'standard'
    tags: union(tags, {
      'hidden-title': 'AI Search Public PE'
    })
  }
}

module storageAccountRoleAssignment '../modules/iam/role-assignment-storage.bicep' = {
  name: take('storage-role-${searchServicePublicPe.name}-assignment-deployment', 64)
  params: {
    azureStorageName: ai_dependencies.outputs.AI_DEPENDECIES.azureStorage.name
    projectPrincipalId: searchServicePublicPe.outputs.systemAssignedMIPrincipalId
  }
}

module storageAccountRoleForUserAssignment '../modules/iam/role-assignment-storage.bicep' = if (!empty(principalId)) {
  name: 'storage-role-user-assignment-deployment'
  params: {
    azureStorageName: ai_dependencies.outputs.AI_DEPENDECIES.azureStorage.name
    projectPrincipalId: principalId!
    servicePrincipalType: 'User'
  }
}

module foundryCognitiveUserRoleAssignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('foundry-cog-user-role-${searchServicePublicPe.name}-assignment-deployment', 64)
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectPrincipalId: searchServicePublicPe.outputs.systemAssignedMIPrincipalId
    roleName: 'Cognitive Services User'
  }
}

module foundryOpenAIUserRoleAssignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('foundry-openai-user-role-${searchServicePublicPe.name}-assignment-deployment', 64)
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectPrincipalId: searchServicePublicPe.outputs.systemAssignedMIPrincipalId
    roleName: 'Cognitive Services OpenAI User'
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
        name: 'gpt-4o'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4o'
            version: '2024-11-20'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
      {
        name: 'gpt-5-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5-mini'
            version: '2025-08-07'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
      {
        name: 'text-embedding-ada-002'
        properties: {
          model: {
            name: 'text-embedding-ada-002'
            version: '2'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'embed-v-4-0'
        properties: {
          model: {
            format: 'Cohere'
            name: 'embed-v-4-0'
            version: '1'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 100
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

resource acount_connection_azureai_search_public_pe 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  name: 'ai-search-public-pe-${resourceToken}-connection'
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
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_RESOURCE_ID string = foundry.outputs.FOUNDRY_RESOURCE_ID
output FOUNDRY_LLM_DEPLOYMENT_NAME string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[0]
output FOUNDRY_CHAT_DEPLOYMENT_NAME string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[1]
output FOUNDRY_EMBEDDING_DEPLOYMENT string = foundry.outputs.FOUNDRY_DEPLOYMENT_NAMES[2]
output FOUNDRY_OPENAI_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.openai.azure.com/'
output FOUNDRY_COGNITIVE_SERVICE_ENDPOINT string = foundry.outputs.FOUNDRY_ENDPOINT

output STORAGE_ACCOUNT_NAME string = ai_dependencies.outputs.AI_DEPENDECIES.azureStorage.name
output STORAGE_ACCOUNT_RESOURCE_ID string = ai_dependencies.outputs.AI_DEPENDECIES.azureStorage.resourceId

output AI_PROJECT_CONNECTION_STRING string = projects[0].outputs.FOUNDRY_PROJECT_CONNECTION_STRING

output AI_SEARCH_SERVICE_PUBLIC_PE string = searchServicePublicPe.outputs.endpoint
output AI_SEARCH_PE string = 'https://${ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name}.search.windows.net'
output AI_SEARCH_PE_NAME string = ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name

output AI_SEARCH_SERVICE_PE_CONNECTION_NAME string = '${ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name}-for-${projects[0].outputs.FOUNDRY_PROJECT_NAME}'
output AI_SEARCH_SERVICE_PUBLIC_PE_CONNECTION_NAME string = acount_connection_azureai_search_public_pe.name

output AZURE_TENANT_ID string = tenant().tenantId
output FOUNDRY_PROJECT_NAME string = projects[0].outputs.FOUNDRY_PROJECT_NAME
