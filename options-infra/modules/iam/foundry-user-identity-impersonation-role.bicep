targetScope = 'subscription'

@description('Foundry account resource ID under which the custom role can be assigned.')
param foundryAccountResourceId string

@description('Custom role display name.')
param roleName string = 'Foundry Agent User Identity Impersonation'

var roleDefinitionName = guid(subscription().id, roleName)

resource roleDefinition 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefinitionName
  properties: {
    roleName: roleName
    description: 'Lets a trusted middle-tier service delegate an end-user identity to a hosted agent.'
    type: 'CustomRole'
    permissions: [
      {
        actions: []
        notActions: []
        dataActions: [
          'Microsoft.CognitiveServices/accounts/AIServices/agents/endpoints/UserIdentityImpersonation/action'
        ]
        notDataActions: []
      }
    ]
    assignableScopes: [
      foundryAccountResourceId
    ]
  }
}

output roleDefinitionId string = roleDefinition.id
