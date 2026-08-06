// ============================================================================
// Azure API Center
// ----------------------------------------------------------------------------
// Deploys an API Center service and links it to an APIM instance so every
// API published to APIM (including the MCP tools registered here) is
// mirrored into the API Center inventory automatically.
//
// The system-assigned managed identity on API Center is granted the
// `API Management Service Reader Role` on the target APIM so the
// `apiSources` link can enumerate APIs.
// ============================================================================
param name string
param location string = resourceGroup().location
param tags object = {}

@description('Full resource ID of the APIM service to link as an API source.')
param apimResourceId string

@description('API Center SKU. Only `Free` is generally available; use `Standard` if the developer portal preview features are enabled in the subscription.')
@allowed(['Free', 'Standard'])
param sku string = 'Free'

// API Center has limited regional availability. When `location` isn't in the
// supported list we fall back to `eastus` so deployments from newer regions
// (e.g. westus3, swedencentral variants) still succeed. Kept in-module so every
// caller inherits the fallback automatically.
// https://learn.microsoft.com/azure/api-center/overview#region-availability
var apiCenterSupportedRegions = [
  'eastus'
  'westeurope'
  'uksouth'
  'centralindia'
  'australiaeast'
  'francecentral'
  'swedencentral'
  'canadacentral'
]
var effectiveLocation = contains(apiCenterSupportedRegions, location) ? location : 'eastus'

var apimIdParts = split(apimResourceId, '/')
var apimSubscriptionId = apimIdParts[2]
var apimResourceGroupName = apimIdParts[4]
var apimName = last(apimIdParts)

resource apiCenter 'Microsoft.ApiCenter/services@2024-03-01' = {
  name: name
  location: effectiveLocation
  tags: tags
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// Grant API Center's MI reader access on the APIM so it can enumerate APIs.
module apicReaderOnApim '../iam/apim-role-assignment.bicep' = {
  name: 'apic-reader-on-apim'
  scope: resourceGroup(apimSubscriptionId, apimResourceGroupName)
  params: {
    apimName: apimName
    principalId: apiCenter.identity.principalId
    roleName: 'API Management Service Reader Role'
  }
}

resource defaultWorkspace 'Microsoft.ApiCenter/services/workspaces@2024-03-01' existing = {
  parent: apiCenter
  name: 'default'
}

// Link APIM to API Center — populates the Integrations blade and auto-imports
// every API from APIM on a schedule (`importSpecification: 'always'`).
resource apimIntegration 'Microsoft.ApiCenter/services/workspaces/apiSources@2024-06-01-preview' = {
  parent: defaultWorkspace
  name: 'apim-integration'
  properties: {
    azureApiManagementSource: {
      resourceId: apimResourceId
    }
    importSpecification: 'always'
    targetLifecycleStage: 'production'
  }
  dependsOn: [
    apicReaderOnApim
  ]
}

output apiCenterName string = apiCenter.name
output apiCenterId string = apiCenter.id
output apiCenterPrincipalId string = apiCenter.identity.principalId
output apiCenterLocation string = effectiveLocation
