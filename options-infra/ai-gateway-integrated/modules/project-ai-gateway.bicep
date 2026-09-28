/*
  Enables a Foundry account and one of its projects on an existing AI Gateway.

  This follows the microsoft-foundry/foundry-samples project-ai-gateway pattern:
  - account -> APIM service resource link
  - per-project APIM product
  - product -> shared API association
  - active APIM subscription scoped to the product
  - project -> APIM product resource link
*/

param aiFoundryAccountName string
param projectName string
param apimResourceId string
param sharedApiId string

var apimServiceName = split(apimResourceId, '/')[8]
// Foundry correlates products by the complete account and project names.
// Keep only the uniqueness suffix short; APIM product IDs support this length.
var productName = toLower('${aiFoundryAccountName}-${projectName}-ai-${take(uniqueString(subscription().id, resourceGroup().id, aiFoundryAccountName, projectName), 10)}')
var productScope = '${apimResourceId}/products/${productName}'

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryAccountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: aiFoundry
  name: projectName
}

resource apim 'Microsoft.ApiManagement/service@2022-08-01' existing = {
  name: apimServiceName
}

// Foundry's gateway registration creates an account-named backend marker.
// Account APIs keep using the shared per-model policy and do not route through
// this backend directly.
resource product 'Microsoft.ApiManagement/service/products@2022-08-01' = {
  parent: apim
  name: productName
  properties: {
    displayName: productName
    subscriptionRequired: true
    state: 'published'
  }
}

resource productApi 'Microsoft.ApiManagement/service/products/apis@2022-08-01' = {
  parent: product
  name: sharedApiId
}

resource productSubscription 'Microsoft.ApiManagement/service/subscriptions@2022-08-01' = {
  parent: apim
  name: productName
  properties: {
    displayName: productName
    scope: product.id
    state: 'active'
    allowTracing: false
  }
}

resource projectGatewayLink 'Microsoft.Resources/links@2016-09-01' = {
  scope: project
  // Portal-generated link names are opaque and short. Using a deterministic
  // hash avoids the 64-character Microsoft.Resources/links name limit.
  name: uniqueString(project.id, productScope)
  properties: {
    targetId: productScope
  }
  dependsOn: [
    productApi
    productSubscription
  ]
}

output productName string = productName
output productResourceId string = product.id
output subscriptionName string = productSubscription.name
output gatewayProductScope string = productScope
