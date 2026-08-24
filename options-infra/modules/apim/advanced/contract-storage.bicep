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

@description('Pre-compiled contracts JSON string from the parent module.')
param contractMapJson string

@description('APIM managed identity principal ID — granted Storage Blob Data Reader')
param apimPrincipalId string

@description('Optional user principal ID that uploads the initial contracts blob from an azd postprovision hook.')
param contractUploaderPrincipalId string = ''

@description('Upload the initial contracts blob with an Azure CLI deployment script. Disable when an azd postprovision hook performs the upload.')
param useDeploymentScriptUpload bool = true

// -- Storage Account (AVM) ----------------------------------------------------
var storageAccountName = take('stcontracts${resourceSuffix}', 24)
var uploaderRoleAssignments = empty(contractUploaderPrincipalId)
  ? []
  : [
      {
        principalId: contractUploaderPrincipalId
        principalType: 'User'
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      }
    ]
var deploymentScriptRoleAssignments = useDeploymentScriptUpload
  ? [
      {
        principalId: scriptIdentity!.properties.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
      }
    ]
  : []

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
    roleAssignments: concat(
      [
        {
          principalId: apimPrincipalId
          principalType: 'ServicePrincipal'
          roleDefinitionIdOrName: 'Storage Blob Data Reader'
        }
      ],
      uploaderRoleAssignments,
      deploymentScriptRoleAssignments
    )
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

// -- Optional deployment-script upload ---------------------------------------
resource scriptIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (useDeploymentScriptUpload) {
  name: 'id-contract-upload-${resourceSuffix}'
  location: location
  tags: tags
}

resource uploadScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = if (useDeploymentScriptUpload) {
  name: 'upload-contracts-${resourceSuffix}'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${scriptIdentity!.id}': {}
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

// -- Outputs ------------------------------------------------------------------
output storageAccountName string = storageAccount.outputs.name
output containerName string = 'contracts'
output blobName string = 'access-contracts.json'
#disable-next-line outputs-should-not-contain-secrets
output blobUrl string = '${storageAccount.outputs.primaryBlobEndpoint}contracts/access-contracts.json'
