// ============================================================================
// Contract Config — APIM Named Value
// ============================================================================
// Stores pre-compiled access contracts JSON as an APIM Named Value.
// Alternative to contract-storage.bicep (Blob Storage) for simpler deployments
// with fewer contracts.
//
// Limitation: APIM Named Values have a 4096 character value limit.
// Use contract-storage.bicep (Blob Storage) for larger contract sets.
// ============================================================================

param apimServiceName string

@description('Pre-compiled contracts JSON string (from parent module)')
param contractMapJson string

// -- Validation: Named Values have a 4096 char limit -------------------------
var _ = length(contractMapJson) > 4096
  ? fail('Contracts JSON is ${length(contractMapJson)} characters, exceeding the APIM Named Value limit of 4096. Use useStorageAccount = true for larger contract sets.')
  : true

// -- APIM Named Value ---------------------------------------------------------
resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource contractsNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimService
  name: 'access-contracts-json'
  properties: {
    displayName: 'access-contracts-json'
    value: contractMapJson
    secret: false
    tags: ['access-contracts', 'auto-generated']
  }
}

// -- Outputs ------------------------------------------------------------------
output namedValueName string = contractsNamedValue.name
output validationResult bool = _
