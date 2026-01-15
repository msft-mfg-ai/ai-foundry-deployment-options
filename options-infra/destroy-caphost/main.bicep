import * as types from '../modules/types/types.bicep'

param location string = resourceGroup().location
param foundryName string
param projectName string

@description('EXISTING AI Search Resource Id in Foundry VNet')
param existingAISearchId string

@description('Name of the EXISTING Cosmos DB Id in App VNet')
param existingCosmosDBId string

@description('Name of the EXISTING Storage Account Id in App VNet')
param existingStorageId string

// validation
var is_valid = empty(foundryName) || empty(projectName) || empty(existingAISearchId) || empty(existingCosmosDBId) || empty(existingStorageId)
  ? fail('FOUNDRY_NAME, PROJECT_NAME, EXISTING_AI_SEARCH_ID, EXISTING_COSMOS_ID, EXISTING_STORAGE_ID are required')
  : true

// ==================== CREATED RESOURCES ====================
var existingAiSearchSplit = split(existingAISearchId, '/')
var existingStorageSplit = split(existingStorageId, '/')
var existingCosmosDBSplit = split(existingCosmosDBId, '/')

// ✅ REFERENCE: Use existing AI dependencies from App VNet
// Prepare aiDependencies object manually since we're using existing resources
var aiDependencies types.aiDependenciesType = {
  aiSearch: {
    name: existingAiSearchSplit[8]
    resourceId: existingAISearchId
    resourceGroupName: existingAiSearchSplit[4]
    subscriptionId: existingAiSearchSplit[2]
  }
  azureStorage: {
    name: existingStorageSplit[8]
    resourceId: existingStorageId
    resourceGroupName: existingStorageSplit[4]
    subscriptionId: existingStorageSplit[2]
  }
  cosmosDB: {
    name: existingCosmosDBSplit[8]
    resourceId: existingCosmosDBId
    resourceGroupName: existingCosmosDBSplit[4]
    subscriptionId: existingCosmosDBSplit[2]
  }
}

module identity '../modules/iam/identity.bicep' = {
  name: 'script-identity-deployment'
  params: {
    identityName: 'script-identity'
    location: location
    tags: {
      deployedBy: 'bicep'
      'hidden-title': 'For deployment script'
    }
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' existing = {
  parent: foundry
  name: projectName
}

resource AzureAIProjectManagerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'eadc314b-1a2d-4efa-be10-5d325db5065e'
  scope: resourceGroup()
}

resource AzureAIProjectManagerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid('script-identity', AzureAIProjectManagerRole.id, project.id)
  properties: {
    principalId: identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    roleDefinitionId: AzureAIProjectManagerRole.id
    principalType: 'ServicePrincipal'
  }
}

module deleteCaphost '../modules/ai/delete-caphost.bicep' = {
  name: 'delete-caphost-deployment'
  params: {
    foundryName: foundryName
    projectName: projectName
    location: location
    scriptUserAssignedIdentityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    scriptUserAssignedIdentityPrincipalId: identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
  }
}

// this runs the update after deletion is complete
module projectUpdate '../modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-${projectName}-update-with-caphost'
  params: {
    foundryName: foundryName
    location: location
    project_name: projectName
    project_description: project.properties.description
    display_name: project.properties.displayName
    aiDependencies: aiDependencies
    existingAiResourceId: null // can provide existing AI resource in the same region
    managedIdentityResourceId: null // can provide user-assigned identity here
  }
  dependsOn: [
    deleteCaphost
  ]
}

output is_valid bool = is_valid
