param location string = resourceGroup().location
param name string

param logAnalyticsWorkspaceId string
param applicationInsightsId string
param keyVaultId string
param userAssignedManagedIdentityId string
param storageAccountId string

param amlPrivateDnsZoneResourceId string
param notebooksPrivateDnsZoneResourceId string

param privateEndpointsSubnetResourceId string
param containerRegistryId string

param foundryName string?

@allowed([
  'Default'
  'Hub'
])
param kind string = 'Default' //'Hub'
var description string = '${kind == 'Hub' ? 'Foundry account' : 'Machine Learning Workspace'} ${name}'
var friendlyName string = description

// split storage account id to get name and resource group
var storageParts = split(storageAccountId, '/')
var storageAccountName = storageParts[8]

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = if (!empty(foundryName)) {
  name: foundryName!
}

module workspace 'br/public:avm/res/machine-learning-services/workspace:0.13.0' = {
  name: 'aml-${name}-workspace-Deployment'
  params: {
    // Required parameters
    name: name
    sku: 'Basic'
    // Non-required parameters
    friendlyName: friendlyName
    description: description
    associatedApplicationInsightsResourceId: applicationInsightsId
    associatedKeyVaultResourceId: keyVaultId
    associatedStorageAccountResourceId: storageAccountId
    associatedContainerRegistryResourceId: containerRegistryId
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
    managedIdentities: {
      userAssignedResourceIds: [
        userAssignedManagedIdentityId
      ]
    }
    primaryUserAssignedIdentity: userAssignedManagedIdentityId
    provisionNetworkNow: true
    publicNetworkAccess: 'Disabled'

    location: location
    managedNetworkSettings: {
      firewallSku: 'Standard'

      isolationMode: 'AllowOnlyApprovedOutbound'
      outboundRules: {
        // rule1: {
        //   category: 'UserDefined'
        //   destination: {
        //     serviceResourceId: '<serviceResourceId>'
        //     sparkEnabled: true
        //     subresourceTarget: 'blob'
        //   }
        //   type: 'PrivateEndpoint'
        // }
        rule2: {
          category: 'UserDefined'
          destination: 'pypi.org'
          type: 'FQDN'
        }
        rule3: {
          category: 'UserDefined'
          destination: {
            portRanges: '80,443'
            protocol: 'TCP'
            serviceTag: 'AppService'
          }
          type: 'ServiceTag'
        }
      }
    }
    privateEndpoints: [
      {
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: amlPrivateDnsZoneResourceId
            }
            {
              privateDnsZoneResourceId: notebooksPrivateDnsZoneResourceId
            }
          ]
        }
        subnetResourceId: privateEndpointsSubnetResourceId
        tags: {
          Environment: 'Non-Prod'
          'hidden-title': 'Test AML Deployment'
          Role: 'DeploymentValidation'
        }
      }
    ]
    connections: empty(foundryName)
      ? []
      : [
          {
            name: 'aoai-connection'
            category: 'AzureOpenAI'
            isSharedToAll: true
            metadata: {
              ApiVersion: '2024-02-01'
              ApiType: 'azure'
              ResourceId: foundry.id
            }
            target: foundry!.properties.endpoints['OpenAI Language Model Instance API']
            connectionProperties: {
              authType: 'AAD'
            }
          }
          {
            name: 'aoai-contentsafety'
            category: 'AzureOpenAI'
            isSharedToAll: true
            target: foundry!.properties.endpoints['Content Safety']
            metadata: {
              ApiVersion: '2023-07-01-preview'
              ApiType: 'azure'
              ResourceId: foundry.id
            }
            connectionProperties: {
              authType: 'AAD'
            }
          }
          {
            name: 'openai-foundry'
            category: 'AzureOpenAI'
            // group: 'AzureAI'
            connectionProperties: {
              authType: 'AAD'
            }
            target: 'https://${foundryName!}.openai.azure.com/'
            isSharedToAll: true
            metadata: {
              ApiType: 'Azure'
              ResourceId: resourceId('Microsoft.CognitiveServices/accounts', foundryName!)
              ApiVersion: '2023-07-01-preview'
              DeploymentApiVersion: '2023-10-01-preview'
            }
          }
          {
            name: 'cognitive-foundry'
            category: 'AIServices'
            // group: 'AzureAI'
            connectionProperties: {
              authType: 'AAD'
            }
            target: 'https://${foundryName!}.cognitiveservices.azure.com/'
            isSharedToAll: true
            metadata: {
              ApiType: 'Azure'
              ResourceId: resourceId('Microsoft.CognitiveServices/accounts', foundryName!)
              ApiVersion: '2023-07-01-preview'
              DeploymentApiVersion: '2023-10-01-preview'
            }
          }
        ]
    datastores: [
      {
        name: 'workspaceworkingdirectory'
        properties: {
          accountName: storageAccountName
          fileShareName: 'workspaceworkingdirectory'
          credentials: {
            credentialsType: 'None'
          }
          datastoreType: 'AzureFile'
          endpoint: environment().suffixes.storage
          protocol: 'https'
          // resourceGroup: '<resourceGroup>'
          serviceDataAccessAuthIdentity: 'None'
          // subscriptionId: '<subscriptionId>'
        }
      }
    ]
    // sharedPrivateLinkResources: [
    //   {
    //     name: '<name>'
    //     groupId: 'amlworkspace'
    //     privateDnsZoneId: '<privateDnsZoneResourceId>'
    //     roleAssignments: [
    //       {
    //         principalId: '<principalId>'
    //         principalType: 'ServicePrincipal'
    //         roleDefinitionIdOrName: 'Reader'
    //       }
    //     ]
    //   }
    // ]
    systemDatastoresAuthMode: 'Identity'
    tags: {
      Environment: 'Non-Prod'
      'hidden-title': 'Test AML Deployment'
      Role: 'DeploymentValidation'
    }
  }
}
