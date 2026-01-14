// https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/key-vault/vault/README.md
import * as types from 'br/public:avm/res/key-vault/vault:0.13.3'

param location string
param name string
param tags object = {}
param userAssignedManagedIdentityPrincipalIds string[] = []
param principalId string?
param secrets types.secretType[]
param doRoleAssignments bool
param logAnalyticsWorkspaceId string?
param privateEndpointSubnetId string?
param privateEndpointName string = ''
param privateDnsZoneResourceId string = ''
@description('If true, the key vault will allow public access. Not recommended for production scenarios.')
param publicAccessEnabled bool = false

var secretsUserAssignments = [
  for principalIdItem in userAssignedManagedIdentityPrincipalIds: {
    principalId: principalIdItem
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'Key Vault Secrets User'
  }
]

var readerAssignments = [
  for principalIdItem in userAssignedManagedIdentityPrincipalIds: {
    principalId: principalIdItem
    principalType: 'ServicePrincipal'
    roleDefinitionIdOrName: 'Key Vault Reader'
  }
]

module vault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'vault-${name}'
  params: {
    name: name
    location: location
    diagnosticSettings: empty(logAnalyticsWorkspaceId)
      ? []
      : [
          {
            name: 'all-logs-to-log-analytics'
            metricCategories: [
              {
                category: 'AllMetrics'
              }
            ]
            workspaceResourceId: logAnalyticsWorkspaceId
          }
        ]
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicAccessEnabled ? 'Allow' : 'Deny'
    }
    publicNetworkAccess: publicAccessEnabled ? 'Enabled' : 'Disabled'
    roleAssignments: doRoleAssignments
      ? union(
          secretsUserAssignments,
          readerAssignments,
          empty(principalId)
            ? []
            : [
                {
                  principalId: principalId
                  principalType: 'User'
                  roleDefinitionIdOrName: 'Key Vault Secrets Officer'
                }
              ]
        )
      : []
    privateEndpoints: empty(privateEndpointSubnetId)
      ? null
      : [
          {
            name: privateEndpointName
            subnetResourceId: privateEndpointSubnetId!
            tags: tags
            privateDnsZoneGroup: empty(privateDnsZoneResourceId)
              ? null
              : {
                  privateDnsZoneGroupConfigs: [
                    { privateDnsZoneResourceId: privateDnsZoneResourceId }
                  ]
                }
          }
        ]
    secrets: secrets
    enablePurgeProtection: false
    enableRbacAuthorization: true
    tags: tags
  }
}

output KEY_VAULT_RESOURCE_ID string = vault.outputs.resourceId
output KEY_VAULT_NAME string = vault.outputs.name
output KEY_VAULT_SECRETS_URIS string[] = map(vault.outputs.secrets, s => s.uri)
