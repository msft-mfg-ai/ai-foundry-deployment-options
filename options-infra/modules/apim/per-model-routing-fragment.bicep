// Deploys the per-model-routing APIM policy fragment.
// Referenced from inbound policies via <include-fragment fragment-id="per-model-routing" />.

@description('Name of the APIM service in this resource group.')
param apiManagementName string

@description('Array of model-clean names (no dots/dashes) that have a {model}-ptu-pool deployed. Priority==1 callers route to the PTU pool only when the model appears in this list; otherwise they fall back to the PAYG pool.')
param ptuModels string[] = []

var ptuModelsJson = string(ptuModels)
// XML-encode so the JSON array literal survives intact inside the policy
// attribute value. APIM decodes entity refs before the expression evaluator
// sees the string, so the C# expression receives the original JSON.
var ptuModelsEncoded = replace(
  replace(replace(replace(ptuModelsJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
  '"',
  '&quot;'
)
var fragmentXml = replace(
  loadTextContent('per-model-routing-fragment.xml'),
  '{PTU_MODELS}',
  ptuModelsEncoded
)

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apiManagementName
}

resource perModelRoutingFragment 'Microsoft.ApiManagement/service/policyFragments@2024-05-01' = {
  parent: apim
  name: 'per-model-routing'
  properties: {
    description: 'Extracts requested model from request and routes to {model-clean}-ptu-pool (priority==1, model has PTU) or {model-clean}-payg-pool (otherwise).'
    format: 'rawxml'
    value: fragmentXml
  }
}

output fragmentName string = perModelRoutingFragment.name
output fragmentId string = perModelRoutingFragment.id
