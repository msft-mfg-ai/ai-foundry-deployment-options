param location string
param resourceToken string
param tags object
param foundryName string
param deployerPrincipalId string?
param groupPrincipalId string?
param aiFoundryProjectNames string[] = []

resource foundryExisting 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryName
}

resource aiProjects 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = [
  for projectName in aiFoundryProjectNames: {
    name: projectName
    parent: foundryExisting
  }
]

// assign roles to every project principal to allow Foundry to access the search service
module projectRoleAssignment '../modules/iam/role-assignment-foundryProject.bicep' = [
  for i in range(0, length(aiFoundryProjectNames)): if (!empty(groupPrincipalId)) {
    name: take('project-role-${aiProjects[i].name}-assignment-deployment', 64)
    params: {
      accountName: foundryName
      projectName: aiProjects[i].name
      principalId: groupPrincipalId!
      servicePrincipalType: 'Group'
    }
  }
]

module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage-account-deployment'
  params: {
    name: 'storage${resourceToken}'
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    requireInfrastructureEncryption: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
    roleAssignments: union(
      empty(groupPrincipalId)
        ? []
        : [
            {
              principalId: groupPrincipalId!
              principalType: 'Group'
              roleDefinitionIdOrName: 'Storage Blob Data Contributor'
            }
          ],
      empty(deployerPrincipalId)
        ? []
        : [
            {
              principalId: deployerPrincipalId!
              principalType: 'User'
              roleDefinitionIdOrName: 'Storage Blob Data Contributor'
            }
          ]
    )
    blobServices: {
      containers: [
        {
          name: 'data'
          publicAccess: 'None'
        }
      ]
    }
  }
}

module searchServicePublic 'br/public:avm/res/search/search-service:0.12.0' = {
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
    privateEndpoints: []
    partitionCount: 1
    // replicaCount: 3
    roleAssignments: union(
      empty(groupPrincipalId)
        ? []
        : [
            {
              principalId: groupPrincipalId
              principalType: 'Group'
              roleDefinitionIdOrName: 'Search Service Contributor'
            }
            {
              principalId: groupPrincipalId
              principalType: 'Group'
              roleDefinitionIdOrName: 'Search Index Data Contributor'
            }
          ],
      empty(deployerPrincipalId)
        ? []
        : [
            {
              principalId: deployerPrincipalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Service Contributor'
            }
            {
              principalId: deployerPrincipalId
              principalType: 'User'
              roleDefinitionIdOrName: 'Search Index Data Contributor'
            }
          ]
    )
    sharedPrivateLinkResources: [
      {
        name: 'ai-foundry-connection-${resourceToken}'
        groupId: 'cognitiveservices_account'
        privateLinkResourceId: foundryExisting.id
        requestMessage: 'Please approve the connection.'
      }
      {
        name: 'blob-connection-${resourceToken}'
        groupId: 'blob'
        privateLinkResourceId: storageAccount.outputs.resourceId
        requestMessage: 'Please approve the connection.'
      }
    ]
    semanticSearch: 'free'
    sku: 'standard'
    tags: tags
  }
}

module storageAccountRoleAssignment '../modules/iam/role-assignment-storage.bicep' = {
  name: take('storage-role-${searchServicePublic.name}-assignment-deployment', 64)
  params: {
    azureStorageName: storageAccount.outputs.name
    principalId: searchServicePublic.outputs.systemAssignedMIPrincipalId
  }
}

// assign roles to every project principal to allow Foundry to access the search service
module searchRoleAssignment '../modules/iam/ai-search-role-assignments.bicep' = [
  for i in range(0, length(aiFoundryProjectNames)): {
    name: take('search-role-${aiProjects[i].name}-assignment-deployment', 64)
    params: {
      aiSearchName: searchServicePublic.outputs.name
      principalId: aiProjects[i].identity.principalId
    }
  }
]

module foundryCognitiveUserRoleAssignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('foundry-cog-user-role-${searchServicePublic.name}-assignment-deployment', 64)
  params: {
    accountName: foundryExisting.name
    principalId: searchServicePublic.outputs.systemAssignedMIPrincipalId!
    roleName: 'Cognitive Services User'
  }
}

module foundryOpenAIUserRoleAssignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: take('foundry-openai-user-role-${searchServicePublic.name}-assignment-deployment', 64)
  params: {
    accountName: foundryExisting.name
    principalId: searchServicePublic.outputs.systemAssignedMIPrincipalId
    roleName: 'Cognitive Services OpenAI User'
  }
}

resource acount_connection_azureai_search_public 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = {
  name: 'ai-search-public-pe-${resourceToken}-connection'
  parent: foundryExisting
  properties: {
    category: 'CognitiveSearch'
    isSharedToAll: true
    target: searchServicePublic.outputs.endpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchServicePublic.outputs.resourceId
      location: searchServicePublic.outputs.location
    }
  }
}

output STORAGE_ACCOUNT_NAME string = storageAccount.outputs.name
output STORAGE_ACCOUNT_RESOURCE_ID string = storageAccount.outputs.resourceId
output AI_SEARCH_SERVICE_PUBLIC_ENDPOINT string = searchServicePublic.outputs.endpoint
output AI_SEARCH_SERVICE_PUBLIC_RESOURCE_ID string = searchServicePublic.outputs.resourceId
output AI_SEARCH_NAME string = searchServicePublic.outputs.name
output AI_SEARCH_CONNECTION_NAME string = acount_connection_azureai_search_public.name
