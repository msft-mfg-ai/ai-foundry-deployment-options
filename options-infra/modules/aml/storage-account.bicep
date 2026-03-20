// https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/storage/storage-account
param location string
param tags object = {}
param name string
param doRoleAssignments bool = true

param userAssignedManagedIdentityPrincipalId string
param logAnalyticsWorkspaceId string

param privateEndpointSubnetId string?
param blobPrivateDnsZoneResourceId string = ''
param filePrivateDnsZoneResourceId string = ''

param containerName string = 'container-001'

@description('If true, resources will be deployed with high availability (multi-zone, multi-region when possible)')
param haDeploymentEnabled bool = false

@description('If true, the storage account will allow public access. Not recommended for production scenarios.')
param publicAccessEnabled bool = false

module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storageAccount-${name}'
  params: {
    name: name
    location: location
    skuName: haDeploymentEnabled ? 'Standard_RAGZRS' : 'Standard_LRS'
    kind: 'StorageV2'
    requireInfrastructureEncryption: false
    allowBlobPublicAccess: false
    tags: tags
    fileServices: {
      shares: [
        {
          name: 'workspaceworkingdirectory'
          shareQuota: 1
          diagnosticSettings: [
            {
              metricCategories: [
                {
                  category: 'AllMetrics'
                }
              ]
              name: 'all'
              workspaceResourceId: logAnalyticsWorkspaceId
            }
          ]
        }
      ]
    }
    blobServices: {
      automaticSnapshotPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 10
      containerDeleteRetentionPolicyEnabled: true
      containers: [
        {
          name: containerName
          publicAccess: 'None'
        }
      ]
      deleteRetentionPolicyDays: 9
      deleteRetentionPolicyEnabled: true
      diagnosticSettings: [
        {
          metricCategories: [
            {
              category: 'AllMetrics'
            }
          ]
          name: 'all'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
      lastAccessTimeTrackingPolicyEnabled: true
    }
    publicNetworkAccess: publicAccessEnabled ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicAccessEnabled ? 'Allow' : 'Deny'
    }
    roleAssignments: doRoleAssignments
      ? [
          {
            principalId: userAssignedManagedIdentityPrincipalId
            principalType: 'ServicePrincipal'
            roleDefinitionIdOrName: 'Storage Blob Data Contributor'
          }
          {
            principalId: userAssignedManagedIdentityPrincipalId
            principalType: 'ServicePrincipal'
            roleDefinitionIdOrName: 'Storage File Data Privileged Contributor'
          }
        ]
      : []
    privateEndpoints: empty(privateEndpointSubnetId)
      ? null
      : [
          {
            name: '${name}-blob-pe'
            privateDnsZoneGroup: empty(blobPrivateDnsZoneResourceId)
              ? null
              : {
                  privateDnsZoneGroupConfigs: [
                    {
                      privateDnsZoneResourceId: blobPrivateDnsZoneResourceId
                    }
                  ]
                }
            service: 'blob'
            subnetResourceId: privateEndpointSubnetId!
            roleAssignments: [
              {
                principalId: userAssignedManagedIdentityPrincipalId
                principalType: 'ServicePrincipal'
                roleDefinitionIdOrName: 'Reader'
              }
            ]
          }
          {
            name: '${name}-file-pe'
            privateDnsZoneGroup: empty(filePrivateDnsZoneResourceId)
              ? null
              : {
                  privateDnsZoneGroupConfigs: [
                    {
                      privateDnsZoneResourceId: filePrivateDnsZoneResourceId
                    }
                  ]
                }
            service: 'file'
            subnetResourceId: privateEndpointSubnetId!
            roleAssignments: [
              {
                principalId: userAssignedManagedIdentityPrincipalId
                principalType: 'ServicePrincipal'
                roleDefinitionIdOrName: 'Reader'
              }
            ]
          }
        ]
  }
}

output AZURE_STORAGE_ACCOUNT_ID string = storageAccount.outputs.resourceId
output AZURE_STORAGE_ACCOUNT_NAME string = storageAccount.outputs.name
output AZURE_STORAGE_ACCOUNT_CONTAINER_NAME string = containerName
