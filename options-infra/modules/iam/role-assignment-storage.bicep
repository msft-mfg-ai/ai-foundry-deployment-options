import * as types from '../types/types.bicep'

param azureStorageName string
param projectPrincipalId string

param roleName types.StorageRoleAssignmentsType = 'Storage Blob Data Contributor'
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param servicePrincipalType string = 'ServicePrincipal'

var roleDefinitionIds = {
  'Storage Blob Data Contributor': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  )
  'Storage Blob Data Owner': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  )
  'Storage Blob Data Reader': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  )
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: azureStorageName
  scope: resourceGroup()
}


resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(projectPrincipalId, roleDefinitionIds[roleName], storageAccount.id)
  properties: {
    principalId: projectPrincipalId
    roleDefinitionId: roleDefinitionIds[roleName]
    principalType: servicePrincipalType
  }
}
