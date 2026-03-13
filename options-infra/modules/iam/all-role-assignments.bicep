import * as types from '../types/types.bicep'

param aiDependencies types.aiDependenciesType
param userPrincipalId string

param aiServicesName string?
param aiServicesResourceGroupName string = resourceGroup().name
param aiServicesSubscriptionId string = subscription().subscriptionId

param foundryName string
param projectName string
param foundryResourceGroupName string = resourceGroup().name
param foundrySubscriptionId string = subscription().subscriptionId

param roleAssignments types.FoundryRoleAssignmentsType

module storageRoleAssignments 'role-assignment-storage.bicep' = [
  for role in roleAssignments.storage: {
    name: take('role-assignments-storage-${replace(role,' ','')}', 64)
    scope: resourceGroup(aiDependencies.azureStorage.subscriptionId, aiDependencies.azureStorage.resourceGroupName)
    params: {
      azureStorageName: aiDependencies.azureStorage.name
      principalId: userPrincipalId
      servicePrincipalType: 'User'
      roleName: role
    }
  }
]

module aiSearchRoleAssignments 'role-assignment-search.bicep' = [
  for role in roleAssignments.aiSearch: {
    name: take('role-assignments-ai-search-${replace(role,' ','')}', 64)
    scope: resourceGroup(aiDependencies.aiSearch.subscriptionId, aiDependencies.aiSearch.resourceGroupName)
    params: {
      aiSearchName: aiDependencies.aiSearch.name
      principalId: userPrincipalId
      servicePrincipalType: 'User'
      roleName: role
    }
  }
]

module foundryProjectRoleAssignments 'role-assignment-foundryProject.bicep' = [
  for role in roleAssignments.project: {
    name: take('role-assignments-foundry-project-${replace(role,' ','')}', 64)
    scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
    params: {
      accountName: foundryName
      projectName: projectName
      principalId: userPrincipalId
      servicePrincipalType: 'User'
      roleName: role
    }
  }
]

module foundryRoleAssignments 'role-assignment-cognitiveServices.bicep' = [
  for role in roleAssignments.foundry: {
    name: take('role-assignments-foundry-account-${replace(role,' ','')}', 64)
    scope: resourceGroup(foundrySubscriptionId, foundryResourceGroupName)
    params: {
      accountName: foundryName
      principalId: userPrincipalId
      servicePrincipalType: 'User'
      roleName: role
    }
  }
]

module aiServicesRoleAssignments 'role-assignment-cognitiveServices.bicep' = [
  for role in roleAssignments.aiServices: if (aiServicesName != null) {
    name: take('role-assignments-ai-services-account-${replace(role,' ','')}', 64)
    scope: resourceGroup(aiServicesSubscriptionId, aiServicesResourceGroupName)
    params: {
      accountName: aiServicesName!
      principalId: userPrincipalId
      servicePrincipalType: 'User'
      roleName: role
    }
  }
]
