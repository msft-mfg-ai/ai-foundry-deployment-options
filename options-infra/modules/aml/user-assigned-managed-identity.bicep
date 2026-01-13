param location string
param name string
param tags object = {}

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'identity-${name}'
  params: {
    tags: tags
    name: name
    location: location
  }
}

output USER_ASSIGNED_IDENTITY_ID string = identity.outputs.resourceId
output USER_ASSIGNED_IDENTITY_CLIENT_ID string = identity.outputs.clientId
output USER_ASSIGNED_IDENTITY_PRINCIPAL_ID string = identity.outputs.principalId
output USER_ASSIGNED_IDENTITY_NAME string = identity.outputs.name
