// Deploys a Function App with its own App Service Plan and Storage Account
// Public access is disabled. No VNET integration. Uses zip deployment for source code.
param name string
param location string
param artifactUrl string // URL to zip file with function code
param managedIdentityResourceId string
param resourceToken string
param logAnalyticsWorkspaceResourceId string
param applicationInsightResourceId string
param privateEndpointSubnetResourceId string = ''

// --------------------------------------------------------------------------------------------------------------
// split managed identity resource ID to get the name
var identityParts = split(managedIdentityResourceId, '/')
// get the name of the managed identity
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = {
  name: managedIdentityName
}

module virtualNetworkDeployment 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: 'virtual-network-deployment'
  params: {
    addressPrefixes: ['10.0.0.0/16']
    name: 'apps-vnet-${resourceToken}'
    location: location
    subnets: [
      {
        name: 'functions-subnet'
        addressPrefix: '10.0.1.0/24'
        serviceEndpoints: ['Microsoft.Web', 'Microsoft.Storage']
        delegation: 'Microsoft.Web/serverfarms'
      }
      {
        name: 'logic-apps-subnet'
        addressPrefix: '10.0.2.0/24'
        serviceEndpoints: ['Microsoft.Web', 'Microsoft.Storage']
        delegation: 'Microsoft.Web/serverfarms'
      }
      { name: 'pe-subnet', addressPrefix: '10.0.3.0/24' }
    ]
  }
}

// Storage Account for the Function App
module storageAccount 'br/public:avm/res/storage/storage-account:0.31.0' = {
  name: 'storageAccount'
  params: {
    name: take('funstor${resourceToken}', 24)
    location: location
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices, Logging, Metrics'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: virtualNetworkDeployment.outputs.subnetResourceIds[0] // Use the first subnet for Function App
          ignoreMissingVnetServiceEndpoint: true
        }
        {
          id: virtualNetworkDeployment.outputs.subnetResourceIds[1] // Use the second subnet for Logic Apps
          ignoreMissingVnetServiceEndpoint: true
        }
      ]
    }
    roleAssignments: [
      {
        principalId: identity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Owner'
      }
      {
        principalId: identity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      }
      {
        principalId: identity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Queue Data Contributor'
      }
      {
        principalId: identity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Table Data Contributor'
      }
    ]

    supportsHttpsTrafficOnly: true
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]
    blobServices: {
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalyticsWorkspaceResourceId
        }
      ]
    }
    queueServices: {
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalyticsWorkspaceResourceId
        }
      ]
      queues: [
        {
          name: 'azure-function-weather-input'
          metadata: {
            purpose: 'Function App queue'
          }
        }
        {
          name: 'azure-function-weather-output'
          metadata: {
            purpose: 'Function App queue'
          }
        }
      ]
    }
    privateEndpoints: [
      {
        subnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[2] // Use the third subnet for Private Endpoints
        service: 'blob'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: storagePrivateDns[0].outputs.resourceId
            }
          ]
        }
      }
      {
        subnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[2] // Use the third subnet for Private Endpoints
        service: 'queue'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: storagePrivateDns[1].outputs.resourceId
            }
          ]
        }
      }
      {
        subnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[2] // Use the third subnet for Private Endpoints
        service: 'table'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: storagePrivateDns[2].outputs.resourceId
            }
          ]
        }
      }
      {
        subnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[2] // Use the third subnet for Private Endpoints
        service: 'file'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: storagePrivateDns[3].outputs.resourceId
            }
          ]
        }
      }
    ]
  }
}

var storageZones = [
  {
    name: 'privatelink.blob.${environment().suffixes.storage}'
  }
  {
    name: 'privatelink.queue.${environment().suffixes.storage}'
  }
  {
    name: 'privatelink.table.${environment().suffixes.storage}'
  }
  {
    name: 'privatelink.file.${environment().suffixes.storage}'
  }
]

module storagePrivateDns 'br/public:avm/res/network/private-dns-zone:0.8.0' = [
  for zone in storageZones: {
    name: 'privateDnsZoneDeployment-${zone.name}'
    params: {
      // Required parameters
      name: zone.name
      // Non-required parameters
      location: 'global'
      virtualNetworkLinks: [
        { virtualNetworkResourceId: virtualNetworkDeployment.outputs.resourceId }
      ]
    }
  }
]

// module serverfarm 'br/public:avm/res/web/serverfarm:0.4.1' = {
//   name: 'serverfarmDeployment'
//   params: {
//     name: 'asp-${resourceToken}'
//     kind: 'elastic'
//     skuName: 'WS1'
//     skuCapacity: 1
//     zoneRedundant: false
//     maximumElasticWorkerCount: 1
//   }
// }

resource serverfarmForLogicApps 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'logic-apps-plan-${resourceToken}'
  location: location
  sku: {
    name: 'WS1'
  }
  kind: 'elastic'
}

resource serverfarmForFunctions 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'function-apps-plan-${resourceToken}'
  location: location
  sku: {
    name: 'B1'
  }
  kind: 'linux'
  properties: {
    reserved: true // Linux
  }
}

module func 'br/public:avm/res/web/site:0.20.0' = {
  name: 'function-deployment'
  params: {
    location: location
    // Required parameters
    kind: 'functionapp'
    name: 'fun-${name}-${resourceToken}'
    serverFarmResourceId: serverfarmForFunctions.id
    managedIdentities: { userAssignedResourceIds: [managedIdentityResourceId] }
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[0] // Use the first subnet for Function App
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
    }
    outboundVnetRouting: {
      contentShareTraffic: true
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]
    configs: [
      {
        name: 'appsettings'
        properties: {
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: 'python'
          WEBSITE_RUN_FROM_PACKAGE: artifactUrl
          AZURE_CLIENT_ID: identity.properties.clientId
          AzureWebJobsStorage__credential: 'managedidentity'
          // AzureWebJobsStorage__credentialType: 'managedidentity'
          AzureWebJobsStorage__managedIdentityResourceId: managedIdentityResourceId
          AzureWebJobsStorage__clientId: identity.properties.clientId
          // AzureWebJobsStorage__accountName: storageAccount.outputs.name
          SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
          ENABLE_ORYX_BUILD: 'true'
        }

        storageAccountResourceId: storageAccount.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
        applicationInsightResourceId: applicationInsightResourceId
      }
    ]
    privateEndpoints: !empty(privateEndpointSubnetResourceId)
      ? [
          {
            subnetResourceId: privateEndpointSubnetResourceId
            service: 'sites'
          }
        ]
      : []
  }
}

module logicApp 'br/public:avm/res/web/site:0.20.0' = {
  name: 'logicAppDeployment'
  params: {
    // Required parameters
    location: location
    kind: 'functionapp,workflowapp'
    name: '${name}-${resourceToken}'
    serverFarmResourceId: serverfarmForLogicApps.id
    managedIdentities: { userAssignedResourceIds: [managedIdentityResourceId] }
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetResourceId: virtualNetworkDeployment.outputs.subnetResourceIds[1] // Use the second subnet for Logic Apps
    outboundVnetRouting: {
      allTraffic: true
      contentShareTraffic: true
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceResourceId
      }
    ]
    httpsOnly: true
    configs: [
      {
        name: 'appsettings'
        properties: {
          FUNCTIONS_EXTENSION_VERSION: '~4'
          FUNCTIONS_WORKER_RUNTIME: 'dotnet'
          APP_KIND: 'workflowApp'
          // https://review.learn.microsoft.com/en-us/azure/logic-apps/create-single-tenant-workflows-azure-portal?branch=main&branchFallbackFrom=pr-en-us-279972#set-up-managed-identity-access-to-your-storage-account
          AZURE_CLIENT_ID: identity.properties.clientId
          AzureWebJobsStorage__credential: 'managedIdentity'
          AzureWebJobsStorage__credentialType: 'managedIdentity'
          AzureWebJobsStorage__managedIdentityResourceId: managedIdentityResourceId
          AzureWebJobsStorage__clientId: identity.properties.clientId
          AzureWebJobsStorage__accountName: storageAccount.outputs.name
          AzureWebJobsSecretStorageType: 'files'
          WEBSITE_NODE_DEFAULT_VERSION: '~22'
          AzureFunctionsJobHost__extensionBundle__id: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
          AzureFunctionsJobHost__extensionBundle__version: '[1.*, 2.0.0)'
        }
        storageAccountResourceId: storageAccount.outputs.resourceId
        storageAccountUseIdentityAuthentication: true
        applicationInsightResourceId: applicationInsightResourceId
      }
    ]
    privateEndpoints: !empty(privateEndpointSubnetResourceId)
      ? [
          {
            subnetResourceId: privateEndpointSubnetResourceId
            service: 'sites'
          }
        ]
      : []
  }
}

output FUNCTION_APP_RESOURCE_ID string = func.outputs.resourceId
output FUNCTION_APP_DEFAULT_HOSTNAME string = func.outputs.defaultHostname
output STORAGE_ACCOUNT_NAME string = storageAccount.outputs.name
output LOGIC_APP_PLAN_NAME string = serverfarmForLogicApps.name
