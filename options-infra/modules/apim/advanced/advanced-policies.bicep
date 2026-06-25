// ============================================================================
// Advanced Config Operations
// ============================================================================
// Adds config viewer/update operations to an existing APIM inference API.
// The endpoints use the Komatsu AI Gateway path shape while attaching to this
// repo's inference API resource.
// ============================================================================

@description('Name of the APIM service in this resource group.')
param apimServiceName string

@description('Name of the parent inference API to attach the config operations to.')
param apiName string

@description('HTTPS URL of the access contracts JSON blob.')
param contractsBlobUrl string

@description('Name of the storage account that stores the contracts blob. APIM managed identity is granted write access for the update operation.')
param storageAccountName string

var contractsLoadBlob = replace(loadTextContent('contracts-load-blob-nocache.xml'), '{blob-url}', contractsBlobUrl)

var configViewerJsonPolicyXml = replace(
  loadTextContent('policy-config-viewer-json.xml'),
  '{contracts-load-section}',
  contractsLoadBlob
)

var configUpdatePolicyXml = replace(
  loadTextContent('policy-config-update.xml'),
  '{contracts-blob-url}',
  contractsBlobUrl
)

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' existing = {
  parent: apimService
  name: apiName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, apimService.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    principalId: apimService.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  }
}

resource configViewerJsonOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'ai-gateway-config-viewer-json'
  properties: {
    displayName: 'Get AI Gateway Config JSON'
    method: 'GET'
    urlTemplate: '/ai-gateway/config.json'
    description: 'Returns all access contracts as raw JSON.'
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [{ contentType: 'application/json' }]
      }
    ]
  }
}

resource configViewerJsonOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: configViewerJsonOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: configViewerJsonPolicyXml
  }
}

resource configUpdateOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'ai-gateway-config-update'
  properties: {
    displayName: 'Update AI Gateway Config'
    method: 'POST'
    urlTemplate: '/ai-gateway/config/update'
    description: 'Updates the access contracts JSON blob and clears APIM contract cache.'
    responses: [
      {
        statusCode: 200
        description: 'OK'
        representations: [{ contentType: 'application/json' }]
      }
    ]
  }
}

resource configUpdateOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: configUpdateOperation
  name: 'policy'
  dependsOn: [storageBlobDataContributor]
  properties: {
    format: 'rawxml'
    value: configUpdatePolicyXml
  }
}
