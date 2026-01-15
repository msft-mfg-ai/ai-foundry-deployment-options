param keyVaultName string
param principalId string

// Conditionally refers your existing Azure Key Vault resource
resource existingKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource keyVaultSecretsOfficer 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'  // Built-in role ID
  scope: resourceGroup()
}

resource rbacAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid(existingKeyVault.id, keyVaultSecretsOfficer.id, principalId)
  scope: existingKeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficer.id
    principalId: principalId
  }
}
