// Minimal, standalone Azure AI Search resource for RBAC-only deployments.
// - disableLocalAuth: TRUE (no admin/query keys, Entra ID only)
// - publicNetworkAccess: enabled (private endpoint deferred; see options-infra/ai-gateway-basic-rbac
//   README if you need to lock it further)
// - authOptions omitted because disableLocalAuth=true excludes it
// Used by ai-gateway-basic-rbac to prove Foundry Users cannot create indexes
// on the underlying Search service.

@description('Name of the Azure AI Search service')
param aiSearchName string

@description('Azure region')
param location string = resourceGroup().location

@description('SKU')
@allowed(['basic', 'standard', 'standard2', 'standard3', 'storage_optimized_l1', 'storage_optimized_l2'])
param sku string = 'basic'

param tags object = {}

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: aiSearchName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    // Entra ID only — no admin or query keys can be created or used.
    disableLocalAuth: true
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    networkRuleSet: {
      bypass: 'AzureServices'
      ipRules: []
    }
    semanticSearch: 'free'
  }
}

output aiSearchName string = aiSearch.name
output aiSearchId string = aiSearch.id
output aiSearchEndpoint string = 'https://${aiSearch.name}.search.windows.net'
