param existing_Foundry_Name string = ''
param existing_Foundry_RG_Name string = resourceGroup().name
param existing_Foundry_SubId string = subscription().subscriptionId
param name string = ''
param location string = resourceGroup().location
param tags object = {}
param agentSubnetResourceId string = ''
@allowed([
  'Disabled'
  'Enabled'
])
param publicNetworkAccess string = 'Enabled'
param disableLocalAuth bool = true
param sku object = {
  name: 'S0'
}
@description('Provide the IP address to allow access to the Azure Container Registry')
param myIpAddress string = ''
param managedIdentityResourceId string?

// Keyvault integration
param keyVaultResourceId string?
@description('Bunch of known issues with KeyVault integration, so disable by default')
param keyVaultConnectionEnabled bool = false

// --------------------------------------------------------------------------------------------------------------
// Variables
// --------------------------------------------------------------------------------------------------------------
var useExistingService = !empty(existing_Foundry_Name)
param deployments aiModelTDeploymentType[] = []

@export()
type aiModelTDeploymentType = {
  @description('The name of the deployment')
  name: string
  properties: {
    model: {
      @description('The name of the model - often the same as the deployment name')
      name: string
      @description('The version of the model, e.g. "2024-11-20" or "0125"')
      version: string
      format: 'OpenAI' | 'Cohere'
    }
  }
  sku: {
    name: 'Standard' | 'GlobalStandard'
    capacity: int
  }?
}

// --------------------------------------------------------------------------------------------------------------
// split managed identity resource ID to get the name
var identityParts = split(managedIdentityResourceId ?? '', '/')
// get the name of the managed identity
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(managedIdentityName)) {
  name: managedIdentityName
}

// --------------------------------------------------------------------------------------------------------------
resource existingAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = if (useExistingService) {
  scope: resourceGroup(existing_Foundry_SubId, existing_Foundry_RG_Name)
  name: existing_Foundry_Name
}

// --------------------------------------------------------------------------------------------------------------
// Foundry is always of type AIServices
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = if (!useExistingService) {
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
    // required to work in AI Foundry
    allowProjectManagement: true
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: disableLocalAuth
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: empty(myIpAddress)
        ? []
        : [
            {
              value: myIpAddress
            }
          ]
      virtualNetworkRules: []
    }
    networkInjections: (!empty(agentSubnetResourceId)
      ? [
          {
            scenario: 'agent'
            subnetArmId: agentSubnetResourceId
            useMicrosoftManagedNetwork: false
          }
        ]
      : null)
    customSubDomainName: toLower('${(name)}')
  }
  sku: sku
}

@batchSize(1)
resource deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [
  for deployment in deployments: if (!useExistingService) {
    parent: account
    name: deployment.name
    properties: deployment.properties
    // use the sku in the deployment if it exists, otherwise default to standard
    sku: deployment.?sku ?? { name: 'Standard', capacity: 20 }
  }
]

// --------------------------------------------------------------------------------------------------------------
// Key Vault integration
// --------------------------------------------------------------------------------------------------------------
var addKeyVault = !empty(keyVaultResourceId) && keyVaultConnectionEnabled
var keyVaultParts string[] = split(keyVaultResourceId ?? '', '/')
var keyVaultName = length(keyVaultParts) > 0 ? last(keyVaultParts) : null
var keyVaultResourceGroupName = length(keyVaultParts) > 4 ? keyVaultParts[4] : null
var keyVaultSubscriptionId = length(keyVaultParts) > 2 ? keyVaultParts[2] : null

// Conditionally refers your existing Azure Key Vault resource
resource existingKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (addKeyVault) {
  name: keyVaultName!
  scope: resourceGroup(keyVaultSubscriptionId!, keyVaultResourceGroupName!)
}

resource foundry_project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = if (addKeyVault && !useExistingService) {
  parent: account
  name: 'project-for-keyvault'
  tags: tags
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Project to enable Key Vault integration'
    displayName: 'Project for Key Vault Integration'
  }
}

@onlyIfNotExists()
resource connection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (addKeyVault && !useExistingService) {
  name: '${name}-keyvault-connection'
  parent: account
  properties: {
    category: 'AzureKeyVault'
    target: existingKeyVault.id
    authType: 'AccountManagedIdentity'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: existingKeyVault.id
      location: existingKeyVault!.location
    }
  }
  dependsOn: [
    foundry_project
  ]
}

// Include RBAC on Key Vault for Foundry
module kvRoleAssignment '../kv/kv-role-assignment.bicep' = if (addKeyVault && !useExistingService) {
  name: 'kv-role-assignment-${name}'
  params: {
    keyVaultName: keyVaultName!
    principalId: empty(managedIdentityResourceId) ? account.?identity.principalId ?? '' : identity.properties.principalId
  }
}
// --------------------------------------------------------------------------------------------------------------
// Outputs
// --------------------------------------------------------------------------------------------------------------
output FOUNDRY_RESOURCE_ID string = useExistingService ? existingAccount.id : account.id
@description('The name of the Foundry Account')
output FOUNDRY_NAME string = useExistingService ? existingAccount.name : account.name
output FOUNDRY_ENDPOINT string = useExistingService ? existingAccount!.properties.endpoint : account!.properties.endpoint
output FOUNDRY_RESOURCE_GROUP_NAME string = useExistingService ? existing_Foundry_RG_Name : resourceGroup().name
output FOUNDRY_SUBSCRIPTION_ID string = useExistingService ? existing_Foundry_SubId : subscription().subscriptionId
output FOUNDRY_PRINCIPAL_ID string = empty(managedIdentityResourceId)
  ? (useExistingService ? (existingAccount.?identity.principalId ?? '') : account.?identity.principalId ?? '')
  : (useExistingService ? '' : identity!.properties.principalId)
output FOUNDRY_DEPLOYMENT_NAMES string[] = [for d in deployments: d.name]
