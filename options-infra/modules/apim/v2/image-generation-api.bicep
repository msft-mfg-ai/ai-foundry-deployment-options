@description('The name of the API Management instance.')
param apiManagementName string

@description('The canonical per-model routing policy.')
param policyXml string

@description('APIM API resource name.')
param apiName string

@description('Public API path without a leading slash.')
param apiPath string

@description('Require an APIM subscription key.')
param requireSubscriptionKey bool = false

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: apiName
  parent: apimService
  properties: {
    apiType: 'http'
    description: 'Image generation operation routed through the canonical per-model gateway policy.'
    displayName: 'AI Image Generation'
    path: apiPath
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: requireSubscriptionKey
    type: 'http'
  }
}

resource operation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'images-generations'
  properties: {
    displayName: 'Create Image'
    method: 'POST'
    urlTemplate: '/images/generations'
    description: 'Generate one image through the unified OpenAI v1 request surface.'
    request: {
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'Image generated.'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

resource policy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}

output apiPath string = api.properties.path
