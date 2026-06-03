// --------------------------------------------------------------------------------------------------------------
// Bicep file to deploy and identity
// --------------------------------------------------------------------------------------------------------------
// Test Deploy Command:
//   az deployment group create -n manual-identity --resource-group rg-ai-docs-114-dev --template-file 'core/iam/identity.bicep' --parameters existingIdentityName='llaz114-app-id'
// --------------------------------------------------------------------------------------------------------------
param identityName string = ''
param existingIdentityName string?
param location string = resourceGroup().location
param tags object = {}

var useExistingIdentity = !empty(existingIdentityName)

resource existingIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (useExistingIdentity) {
  name: existingIdentityName!
}

module botServiceIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = if (!useExistingIdentity) {
  name: '${identityName}-deployment'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

// --------------------------------------------------------------------------------------------------------------
// Outputs
// --------------------------------------------------------------------------------------------------------------
output MANAGED_IDENTITY_RESOURCE_ID string = useExistingIdentity ? existingIdentity.id : botServiceIdentity!.outputs.resourceId
output MANAGED_IDENTITY_NAME string = useExistingIdentity ? existingIdentity.name : botServiceIdentity!.outputs.name
output MANAGED_IDENTITY_CLIENT_ID string = useExistingIdentity
  ? existingIdentity!.properties.clientId
  : botServiceIdentity!.outputs.clientId
output MANAGED_IDENTITY_PRINCIPAL_ID string = useExistingIdentity
  ? existingIdentity!.properties.principalId
  : botServiceIdentity!.outputs.principalId
