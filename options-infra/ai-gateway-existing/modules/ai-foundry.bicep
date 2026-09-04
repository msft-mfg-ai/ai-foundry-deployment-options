// Simplified Foundry account module (no KeyVault, no existing, no deployments)
param name string
param location string = resourceGroup().location
param tags object = {}
param agentSubnetResourceId string = ''

@allowed(['Disabled', 'Enabled'])
param publicNetworkAccess string = 'Enabled'
param disableLocalAuth bool = false
param managedIdentityResourceId string = ''

param sku object = { name: 'S0' }

// split managed identity resource ID to get the name
var identityParts = split(managedIdentityResourceId, '/')
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

// this just checks identity exists
#disable-next-line no-unused-existing-resources
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(managedIdentityName)) {
  name: managedIdentityName
}

resource account 'Microsoft.CognitiveServices/accounts@2026-01-15-preview' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  identity: !empty(managedIdentityResourceId)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${managedIdentityResourceId}': {}
        }
      }
    : {
        type: 'SystemAssigned'
      }
  properties: {
    instant: {
      raiPolicyName: 'Microsoft.DefaultV2'
      // disable instant access models: https://learn.microsoft.com/en-us/azure/foundry/concepts/instant-models?tabs=python%2Cbicep#enterprise-controls
      modelAllowList: []
    }
    allowProjectManagement: true
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: disableLocalAuth
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    networkInjections: !empty(agentSubnetResourceId)
      ? [
          {
            scenario: 'agent'
            subnetArmId: agentSubnetResourceId
            useMicrosoftManagedNetwork: false
          }
        ]
      : null
    customSubDomainName: toLower(name)
  }
  sku: sku
}

output FOUNDRY_RESOURCE_ID string = account.id
output FOUNDRY_NAME string = account.name
output FOUNDRY_ENDPOINT string = account.properties.endpoint
