import * as types from '../types/types.bicep'

param location string
param appName string
param agentSubnetId string
param aiDependencies types.aiDependenciesType

@description('The resource ID of the existing Ai resource - Azure Open AI, AI Services or AI Foundry.')
param existingAiResourceId string

@description('The Kind of AI Service, can be "AzureOpenAI" or "AIServices". For AI Foundry use AI Services. Its not recommended to use Azure OpenAI resource, since that only provided access to OpenAI models.')
@allowed([
  'AzureOpenAI'
  'AIServices'
])
param existingAiResourceKind string = 'AIServices' // Can be 'AzureOpenAI' or 'AIServices'

var resourceToken = toLower(uniqueString(appName, subscription().subscriptionId, location))

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../monitor/loganalytics.bicep' = {
  name: 'law-${appName}'
  params: {
    newLogAnalyticsName: '${appName}-log-analytics'
    newApplicationInsightsName: '${appName}-app-insights'
    location: location
  }
}

module identity '../iam/identity.bicep' = {
  name: 'app-${appName}-identity'
  params: {
    identityName: '${appName}-project-identity'
    location: location
  }
}

module foundry '../ai/ai-foundry.bicep' = {
  name: 'foundry-${appName}'
  scope: resourceGroup()
  params: {
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-no-models-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: agentSubnetId
  }
}

module aiProject '../ai/ai-project.bicep' = {
  name: 'deployment-for-ai-project-${appName}'
  scope: resourceGroup()
  params: {
    foundry_name: foundry.outputs.FOUNDRY_NAME
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    location: location
    project_name: 'ai-project-${appName}'
    project_description: 'AI Project ${appName} with existing, external AI resource ${existingAiResourceId}'
    display_name: 'AI Project ${appName} with ${existingAiResourceKind}'
    managedIdentityResourceId: '' // Use System Assigned Identity
    existingAiResourceId: existingAiResourceId
    existingAiKind: existingAiResourceKind

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
  name: 'format-project-${appName}-workspace-id-deployment'
  scope: resourceGroup()
  params: {
    projectWorkspaceId: aiProject.outputs.FOUNDRY_PROJECT_WORKSPACE_ID
  }
}

//Assigns the project SMI the storage blob data contributor role on the storage account

module storageAccountRoleAssignment '../iam/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-role-${appName}-assignment-deployment'
  scope: resourceGroup(aiDependencies.azureStorage.resourceGroupName)
  params: {
    azureStorageName: aiDependencies.azureStorage.name
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// The Comos DB Operator role must be assigned before the caphost is created
module cosmosAccountRoleAssignments '../iam/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-${appName}-account-ra-project-deployment'
  scope: resourceGroup(aiDependencies.cosmosDB.resourceGroupName)
  params: {
    cosmosDBName: aiDependencies.cosmosDB.name
    projectPrincipalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// This role can be assigned before or after the caphost is created
module aiSearchRoleAssignments '../iam/ai-search-role-assignments.bicep' = {
  name: 'ai-${appName}-search-ra-project-deployment'
  scope: resourceGroup(aiDependencies.aiSearch.resourceGroupName)
  params: {
    aiSearchName: aiDependencies.aiSearch.name
    principalId: aiProject.outputs.FOUNDRY_PROJECT_PRINCIPAL_ID
  }
}

// This module creates the capability host for the project and account
module addProjectCapabilityHost '../ai/add-project-capability-host.bicep' = {
  name: 'capabilityHost-${appName}-configuration-deployment'
  scope: resourceGroup()
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
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
  name: 'storage-${appName}-containers-deployment'
  scope: resourceGroup(aiDependencies.azureStorage.resourceGroupName)
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
  name: 'cosmos-${appName}-ra-${resourceToken}-deployment'
  scope: resourceGroup(aiDependencies.cosmosDB.resourceGroupName)
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
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
