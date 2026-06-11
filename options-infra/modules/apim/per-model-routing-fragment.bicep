// Deploys the per-model-routing APIM policy fragment.
// Referenced from inbound policies via <include-fragment fragment-id="per-model-routing" />.

@description('Name of the APIM service in this resource group.')
param apiManagementName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

resource perModelRoutingFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'per-model-routing'
  properties: {
    description: 'Extracts requested model from request and routes to {model-clean}-payg-pool.'
    format: 'rawxml'
    value: loadTextContent('per-model-routing-fragment.xml')
  }
}

output fragmentName string = perModelRoutingFragment.name
output fragmentId string = perModelRoutingFragment.id
