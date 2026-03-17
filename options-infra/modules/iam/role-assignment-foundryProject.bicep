import * as types from '../types/types.bicep'

param accountName string
param projectName string
param principalId string
param roleName types.CognitiveServicesRoleAssignmentsType = 'Azure AI User'
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param servicePrincipalType string = 'ServicePrincipal'

var roleDefinitionIds = {
  // https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning#cognitive-services-openai-user
  'Cognitive Services OpenAI User': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  )
  'Cognitive Services User': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'a97b65f3-24c7-4388-baec-2e87135dc908'
  )
  'Cognitive Services Contributor': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68'
  )
  // Azure AI User https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry#azure-ai-user
  'Azure AI User': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  )
  Reader: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  'Azure AI Project Manager': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'eadc314b-1a2d-4efa-be10-5d325db5065e'
  )
  'Azure AI Account Owner': subscriptionResourceId(
    'Microsoft.Authorization/roleDefinitions',
    'e47c6f54-e4a2-4754-9501-8e0985b135e1'
  )
}

resource account 'Microsoft.CognitiveServices/accounts@2025-07-01-preview' existing = {
  name: accountName
  scope: resourceGroup()
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-07-01-preview' existing = {
  name: projectName
  parent: account
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: project
  name: guid(principalId, roleDefinitionIds[roleName], project.id)
  properties: {
    principalId: principalId
    roleDefinitionId: roleDefinitionIds[roleName]
    principalType: servicePrincipalType
  }
}
