import * as types from '../types/types.bicep'

param aiSearchName string
param principalId string
param roleName types.SearchRoleAssignmentsType = 'Search Index Data Reader'
@allowed([
  'ServicePrincipal'
  'User'
])
param servicePrincipalType string = 'ServicePrincipal'

var roleDefinitionIds = {
  'Search Index Data Contributor': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  )
  'Search Index Data Reader': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  )
}

resource aiSearch 'Microsoft.Search/searchServices@2025-10-01-preview' existing = {
  name: aiSearchName
  scope: resourceGroup()
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: aiSearch
  name: guid(principalId, roleDefinitionIds[roleName], aiSearch.id)
  properties: {
    principalId: principalId
    roleDefinitionId: roleDefinitionIds[roleName]
    principalType: servicePrincipalType
  }
}
