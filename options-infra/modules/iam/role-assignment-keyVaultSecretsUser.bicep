param keyVaultName string
param principalId string

@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Key Vault Secrets User: read secret values
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-secrets-user
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(principalId, '4633458b-17de-408a-b874-0445c86b69e0', vault.id)
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e0'
    )
    principalType: principalType
  }
}
