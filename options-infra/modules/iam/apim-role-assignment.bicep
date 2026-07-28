@description('Name of the existing API Management service to scope the role assignment to.')
param apimName string

@description('Principal ID to grant the role to (e.g. API Center system-assigned MI).')
param principalId string

@allowed([
  'API Management Service Reader Role'
  'API Management Service Contributor'
  'API Management Developer Portal Content Editor'
])
param roleName string = 'API Management Service Reader Role'

@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param servicePrincipalType string = 'ServicePrincipal'

var roleDefinitionIds = {
  // https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/integration#api-management-service-reader-role
  'API Management Service Reader Role': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '71522526-b88f-4d52-b57f-d31fc3546d0d'
  )
  'API Management Service Contributor': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '312a565d-c81f-4fd8-895a-4e21e48d571c'
  )
  'API Management Developer Portal Content Editor': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'c031e6a8-4391-4de0-8d69-4706a7ed3729'
  )
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
  scope: resourceGroup()
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apim
  name: guid(principalId, roleDefinitionIds[roleName], apim.id)
  properties: {
    principalId: principalId
    roleDefinitionId: roleDefinitionIds[roleName]
    principalType: servicePrincipalType
  }
}
