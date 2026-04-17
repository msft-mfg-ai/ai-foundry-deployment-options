// Simplified identity module — creates or references a user-assigned managed identity
param identityName string
param location string = resourceGroup().location
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' = {
  name: identityName
  location: location
  tags: tags
}

output MANAGED_IDENTITY_RESOURCE_ID string = identity.id
output MANAGED_IDENTITY_NAME string = identity.name
output MANAGED_IDENTITY_CLIENT_ID string = identity.properties.clientId
output MANAGED_IDENTITY_PRINCIPAL_ID string = identity.properties.principalId
