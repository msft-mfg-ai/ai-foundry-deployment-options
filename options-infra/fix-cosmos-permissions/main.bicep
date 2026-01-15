param foundryName string
param projectNames string[] = ['ai-project-1', 'ai-project-2', 'ai-project-3']
param cosmosAccountName string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' existing = {
  name: foundryName
}

resource projects 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = [
  for projectName in projectNames: {
    parent: foundry
    name: projectName
  }
]

module formatProjectWorkspaceIds '../modules/ai/format-project-workspace-id.bicep' = [
  for (projectName, i) in projectNames: {
    name: 'format-project-${projectName}-workspace-id-deployment'
    params: {
      projectWorkspaceId: projects[i].properties.internalId
    }
  }
]

module fixCosmosPermissions '../modules/iam/cosmos-container-role-assignments.bicep' = [
  for (projectName, i) in projectNames: {
    name: 'fix-cosmos-permissions-${projectName}'
    params: {
      cosmosAccountName: cosmosAccountName
      projectPrincipalId: projects[i].identity.principalId
      projectWorkspaceId: formatProjectWorkspaceIds[i].outputs.FOUNDRY_PROJECT_WORKSPACE_ID
    }
  }
]
