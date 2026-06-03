// Deploys the caller-identity APIM policy fragment.
// Referenced from inbound policies via <include-fragment fragment-id="caller-identity" />.

@description('Name of the APIM service in this resource group.')
param apiManagementName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

resource callerIdentityFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'caller-identity'
  properties: {
    description: 'Derives x-caller-* headers (name, id, foundry, project) from JWT, Foundry headers, or APIM subscription.'
    format: 'rawxml'
    value: loadTextContent('caller-identity-fragment.xml')
  }
}

output fragmentName string = callerIdentityFragment.name
output fragmentId string = callerIdentityFragment.id
