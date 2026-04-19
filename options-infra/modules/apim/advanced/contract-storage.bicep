// ============================================================================
// Contract Config Storage
// ============================================================================
// Stores pre-compiled access contracts JSON as a blob in Azure Blob Storage.
// APIM fetches this blob on each request (with short caching) to load contract config.
//
// Why Blob Storage?
//   - APIM Named Values have a 4096-char limit (~15-20 contracts max)
//   - Blob supports up to 200GB (effectively unlimited contracts)
//   - APIM can fetch via send-request with managed identity auth
//   - No external cache (Redis) dependency
//
// Uses AVM storage-account module for consistent resource creation.
// ============================================================================

param location string
param tags object = {}
param resourceSuffix string

@description('Pre-compiled contracts JSON string (from parent module)')
param contractMapJson string

@description('APIM managed identity principal ID — granted Storage Blob Data Reader')
param apimPrincipalId string

// -- Storage Account (AVM) ----------------------------------------------------
var storageAccountName = take('stcontracts${resourceSuffix}', 24)

module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'contract-storage-account'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    requireInfrastructureEncryption: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
    roleAssignments: [
      {
        principalId: apimPrincipalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Reader'
      }
      {
        principalId: scriptIdentity.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      }
    ]
    blobServices: {
      containers: [
        {
          name: 'contracts'
          publicAccess: 'None'
        }
      ]
    }
  }
}

// -- Deploy contract config as a blob -----------------------------------------
// Uses deploymentScript to upload the JSON blob (Bicep can't create blobs natively)
resource uploadScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'upload-contracts-${resourceSuffix}'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.63.0'
    retentionInterval: 'PT1H'
    timeout: 'PT5M'
    forceUpdateTag: uniqueString(contractMapJson)
    environmentVariables: [
      { name: 'STORAGE_ACCOUNT', value: storageAccount.outputs.name }
      { name: 'CONTAINER_NAME', value: 'contracts' }
      { name: 'BLOB_NAME', value: 'access-contracts.json' }
      { name: 'CONTRACT_JSON', value: contractMapJson }
    ]
    scriptContent: '''
      echo "$CONTRACT_JSON" | az storage blob upload \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER_NAME" \
        --name "$BLOB_NAME" \
        --data @- \
        --content-type "application/json" \
        --auth-mode login \
        --overwrite
      echo "Uploaded contracts to $STORAGE_ACCOUNT/$CONTAINER_NAME/$BLOB_NAME"
    '''
  }
}

// -- User-Assigned Identity for deployment script -----------------------------
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-contract-upload-${resourceSuffix}'
  location: location
  tags: tags
}

// -- Outputs ------------------------------------------------------------------
output storageAccountName string = storageAccount.outputs.name
output containerName string = 'contracts'
output blobName string = 'access-contracts.json'
#disable-next-line outputs-should-not-contain-secrets
output blobUrl string = '${storageAccount.outputs.primaryBlobEndpoint}contracts/access-contracts.json'
