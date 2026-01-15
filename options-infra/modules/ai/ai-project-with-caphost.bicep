import * as types from '../types/types.bicep'

param tags object = {}
param aiDependencies types.aiDependenciesType
param existingAiResourceId string?
@allowed([
  'AzureOpenAI'
  'AIServices'
])
param existingAiResourceKind string = 'AIServices'
param location string = resourceGroup().location
param foundryName string
param managedIdentityResourceId string? // Use System Assigned Identity

param projectId int = 1
param project_name string = 'ai-project-${projectId}'
param project_description string = 'AI Project ${projectId}'
param display_name string = 'AI Project ${projectId}'

param appInsightsResourceId string?

module aiProject './ai-project.bicep' = {
  name: 'deployment-for-${project_name}'
  params: {
    tags: tags
    foundry_name: foundryName
    location: location
    project_name: project_name
    project_description: project_description
    display_name: display_name
    managedIdentityResourceId: managedIdentityResourceId // Use System Assigned Identity
    existingAiResourceId: existingAiResourceId
    existingAiKind: existingAiResourceKind
    appInsightsResourceId: appInsightsResourceId

    aiSearchName: aiDependencies.aiSearch.name
    aiSearchServiceResourceGroupName: aiDependencies.aiSearch.resourceGroupName
    aiSearchServiceSubscriptionId: aiDependencies.aiSearch.subscriptionId

    azureStorageName: aiDependencies.azureStorage.name
    azureStorageResourceGroupName: aiDependencies.azureStorage.resourceGroupName
    azureStorageSubscriptionId: aiDependencies.azureStorage.subscriptionId

    cosmosDBName: aiDependencies.cosmosDB.name
    cosmosDBResourceGroupName: aiDependencies.cosmosDB.resourceGroupName
    cosmosDBSubscriptionId: aiDependencies.cosmosDB.subscriptionId
  }
}

module formatProjectWorkspaceId '../ai/format-project-workspace-id.bicep' = {
  name: 'format-${project_name}-workspace-id-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.FOUNDRY_PROJECT_WORKSPACE_ID
  }
}

//Assigns the project SMI the storage blob data contributor role on the storage account

module storageAccountRoleAssignment '../iam/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-role-assignment-deployment-${project_name}'
  scope: resourceGroup(aiDependencies.azureStorage.subscriptionId, aiDependencies.azureStorage.resourceGroupName)
  params: {
    azureStorageName: aiDependencies.azureStorage.name
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments '../iam/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-project-deployment-${project_name}'
  scope: resourceGroup(aiDependencies.cosmosDB.subscriptionId, aiDependencies.cosmosDB.resourceGroupName)
  params: {
    cosmosDBName: aiDependencies.cosmosDB.name
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments '../iam/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-project-deployment-${project_name}'
  scope: resourceGroup(aiDependencies.aiSearch.subscriptionId, aiDependencies.aiSearch.resourceGroupName)
  params: {
    aiSearchName: aiDependencies.aiSearch.name
    principalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// This module creates the capability host for the project and account
module addProjectCapabilityHost 'add-project-capability-host.bicep' = {
  name: 'capabilityHost-configuration-deployment-${project_name}'
  params: {
    accountName: foundryName
    projectName: aiProject.outputs.FOUNDRY_PROJECT_NAME
    cosmosDBConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_COSMOSDB
    azureStorageConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_STORAGE
    aiSearchConnection: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI_SEARCH
    aiFoundryConnectionName: aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_NAME_AI
  }
  dependsOn: [
    cosmosAccountRoleAssignments
    storageAccountRoleAssignment
    aiSearchRoleAssignments
  ]
}

// The Storage Blob Data Owner role must be assigned after the caphost is created
module storageContainersRoleAssignment '../iam/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-deployment-${project_name}'
  scope: resourceGroup(aiDependencies.azureStorage.subscriptionId, aiDependencies.azureStorage.resourceGroupName)
  params: {
    aiProjectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
    storageName: aiDependencies.azureStorage.name
    workspaceId: formatProjectWorkspaceId.outputs.FOUNDRY_PROJECT_WORKSPACE_ID
  }
  dependsOn: [
    addProjectCapabilityHost
  ]
}

// The Cosmos Built-In Data Contributor role must be assigned after the caphost is created
module cosmosContainerRoleAssignments '../iam/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-ra-deployment-${project_name}'
  scope: resourceGroup(aiDependencies.cosmosDB.subscriptionId, aiDependencies.cosmosDB.resourceGroupName)
  params: {
    cosmosAccountName: aiDependencies.cosmosDB.name
    projectWorkspaceId: formatProjectWorkspaceId.outputs.FOUNDRY_PROJECT_WORKSPACE_ID
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = aiProject.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output FOUNDRY_PROJECT_NAME string = aiProject.outputs.FOUNDRY_PROJECT_NAME
