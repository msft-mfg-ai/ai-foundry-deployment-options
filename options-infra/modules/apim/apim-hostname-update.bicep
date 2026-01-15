@description('The suffix to append to the API Management instance name. Defaults to a unique string based on subscription and resource group IDs.')
param resourceSuffix string = uniqueString(subscription().id, resourceGroup().id)

@description('The name of the API Management instance. Defaults to "apim-<resourceSuffix>".')
param apiManagementName string = 'apim-${resourceSuffix}'

@description('The location of the API Management instance. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The email address of the publisher. Defaults to "noreply@microsoft.com".')
param publisherEmail string = 'noreply@microsoft.com'

@description('The name of the publisher. Defaults to "Microsoft".')
param publisherName string = 'Microsoft'

@description('The pricing tier of this API Management service')
@allowed([
  'Consumption'
  'Developer'
  'Basic'
  'Basicv2'
  'Standard'
  'Standardv2'
  'Premium'
  'Premiumv2'
])
param apimSku string = 'Basicv2'

@description('The type of managed identity to by used with API Management')
@allowed([
  'SystemAssigned'
  'UserAssigned'
  'SystemAssigned, UserAssigned'
])
param apimManagedIdentityType string = 'SystemAssigned'

@description('The user-assigned managed identity ID to be used with API Management')
param apimUserAssignedManagedIdentityResourceId string?

@description('The release channel for the API Management service')
@allowed([
  'Early'
  'Default'
  'Late'
  'GenAI'
])
param releaseChannel string = 'Default'

@allowed([
  'External'
  'Internal'
  'None'
])
param virtualNetworkType string = 'None'
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'
param subnetResourceId string?
@description('Custom domain hostname configurations for the API Management service')
param hostnameConfigurations hostnameConfigurationType[] = []
param keyVaultName string
param apimPrincipalId string
param tags object = {}

// ------------------
//    TYPE DEFINITIONS
// ------------------
@export()
type subscriptionType = {
  @description('The name of the subscription.')
  name: string
  @description('Display name of the subscription.')
  displayName: string
}

@export()
type hostnameConfigurationType = {
  @description('The type of hostname configuration.')
  type: 'Management' | 'Portal' | 'Proxy' | 'Scm' | 'DeveloperPortal'
  @description('The custom host name.')
  hostName: string
  @description('The source of the certificate.')
  certificateSource: 'KeyVault' | 'Default'
  @description('The Key Vault ID containing the certificate.')
  keyVaultId: string
}

// add Key Vault role assignment for APIM to access certificates from Key Vault if needed
// ------------------
//    RESOURCES
// ------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (length(hostnameConfigurations) > 0) {
  name: keyVaultName
}

resource certificateUserRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  name: 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
  scope: resourceGroup()
}

resource secretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  name: '4633458b-17de-408a-b874-0445c86b69e6'
  scope: resourceGroup()
}

resource certificateUserRoleAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(apimPrincipalId, certificateUserRole.id, keyVault.id)
  properties: {
    principalId: apimPrincipalId
    roleDefinitionId: certificateUserRole.id
    principalType: 'ServicePrincipal'
  }
}

resource secretsUserRoleAssignmentProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(apimPrincipalId, secretsUserRole.id, keyVault.id)
  properties: {
    principalId: apimPrincipalId
    roleDefinitionId: secretsUserRole.id
    principalType: 'ServicePrincipal'
  }
}

// Update only the hostname configuration using a lightweight resource
resource apimService 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apiManagementName
  location: location
  tags: tags
  sku: {
    name: apimSku
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    releaseChannel: releaseChannel
    virtualNetworkType: virtualNetworkType
    virtualNetworkConfiguration: empty(subnetResourceId)
      ? null
      : {
          subnetResourceId: subnetResourceId
        }
    publicNetworkAccess: publicNetworkAccess
    hostnameConfigurations: hostnameConfigurations
  }
  identity: {
    type: apimManagedIdentityType
    userAssignedIdentities: contains(apimManagedIdentityType, 'UserAssigned') && !empty(apimUserAssignedManagedIdentityResourceId)
      ? {
          // BCP037: Not yet added to latest API:
          '${apimUserAssignedManagedIdentityResourceId}': {}
        }
      : null
  }
}

