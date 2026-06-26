// Deploys the per-model-routing APIM policy fragment.
// Referenced from inbound policies via <include-fragment fragment-id="per-model-routing" />.

import { foundryInstanceType } from 'advanced/types.bicep'

@description('Name of the APIM service in this resource group.')
param apiManagementName string

@description('When true, a {model}-ptu-pool exists for every model that has at least one PTU backend (created by multi-foundry-backends.bicep with priorityRouting=true). The fragment routes priority==1 callers to that pool; everyone else hits the default {model}-pool. When false, the ptu-models list is empty and ALL callers hit {model}-pool (PTU lives inside it as overflow capacity).')
param priorityRouting bool = false

@description('Foundry instances passed to multi-foundry-backends.bicep. Used to compute the list of models that have a {model}-ptu-pool when priorityRouting=true.')
param foundryInstances foundryInstanceType[] = []

// -- Compute models whose {model}-ptu-pool will be created --------------------
// Mirrors the condition in advanced/multi-foundry-backends.bicep: a ptu-pool
// is created whenever priorityRouting=true AND the model has at least one PTU
// backend (PAYG may or may not exist; PAYG members act as fallback inside the
// ptu-pool when present).
var allDeployments = flatten(map(
  foundryInstances,
  inst => map(inst.deployments, d => { modelName: d.modelName, isPtu: inst.isPtu })
))
var uniqueModels = reduce(allDeployments, [], (acc, d) => contains(acc, d.modelName) ? acc : concat(acc, [d.modelName]))
var ptuModels = priorityRouting
  ? map(filter(uniqueModels, m => length(filter(allDeployments, d => d.modelName == m && d.isPtu)) > 0), m => replace(replace(m, '.', ''), '-', ''))
  : []

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
    description: priorityRouting
      ? 'Routes priority==1 callers to {model-clean}-ptu-pool (when PTU exists); other callers to {model-clean}-pool (PAYG-only).'
      : 'Routes all callers to {model-clean}-pool (contains PAYG pri 50/100 and PTU pri 200 overflow).'
    format: 'rawxml'
    value: fragmentXml
  }
}

output fragmentName string = perModelRoutingFragment.name
output fragmentId string = perModelRoutingFragment.id
output ptuPoolModelsClean array = ptuModels
