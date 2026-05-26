// ============================================================================
// APIM Named Value — Key Vault secret reference
// ============================================================================
// Creates an APIM Named Value whose value is sourced from a Key Vault secret.
// The APIM service's system-assigned managed identity must have
// "Key Vault Secrets User" on the vault before this is deployed.
// ============================================================================

param apimServiceName string

@description('The display name used to reference this value in policies, e.g. {{my-secret}}.')
param namedValueName string

@description('Versioned or unversioned Key Vault secret URI, e.g. https://<vault>.vault.azure.net/secrets/<name>.')
param secretUri string

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource namedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimService
  name: namedValueName
  properties: {
    displayName: namedValueName
    secret: true
    keyVault: {
      secretIdentifier: secretUri
    }
  }
}

output namedValueName string = namedValue.name
