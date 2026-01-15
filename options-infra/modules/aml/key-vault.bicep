// https://github.com/Azure/bicep-registry-modules/blob/main/avm/res/key-vault/vault/README.md
import * as types from 'br/public:avm/res/key-vault/vault:0.13.3'

param location string
param name string
param tags object = {}
param userAssignedManagedIdentityPrincipalId string
param principalId string?
param secrets types.secretType[]
param doRoleAssignments bool = true
param logAnalyticsWorkspaceId string
param privateEndpointSubnetId string?
param privateEndpointName string = ''
param privateDnsZoneResourceId string = ''
@description('If true, the key vault will allow public access. Not recommended for production scenarios.')
param publicAccessEnabled bool = false

module vault 'br/public:avm/res/key-vault/vault:0.13.3' = {
  name: 'vault-${name}'
  params: {
    name: name
    location: location
    diagnosticSettings: [
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
          [
            {
              principalId: userAssignedManagedIdentityPrincipalId
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: 'Key Vault Secrets User'
            }
            {
              principalId: userAssignedManagedIdentityPrincipalId
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: 'Key Vault Reader'
            }
          ],
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
            roleAssignments: [
              {
                principalId: userAssignedManagedIdentityPrincipalId
                principalType: 'ServicePrincipal'
                roleDefinitionIdOrName: 'Reader'
              }
            ]
          }
        ]
    secrets: secrets
    enablePurgeProtection: false
    enableRbacAuthorization: true
    tags: tags
  }
}

output KEY_VAULT_ID string = vault.outputs.resourceId
output KEY_VAULT_NAME string = vault.outputs.name
