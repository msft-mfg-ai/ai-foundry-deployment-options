// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis
param apimServiceName string
param apiDefinition string
param serviceURL string
param path string

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

resource apiBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' ={
  parent: apim
  name: '${path}-backend'
  properties: {
    protocol: 'http'
    url: serviceURL
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    type: 'Single'
  }  
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: '${path}-api-tools'
  parent: apim
  properties: {
    apiType: 'http'
    description: '${path} API Tools'
    displayName: '${path} API Tools'
    format: 'openapi+json'
    path: path
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'subscription-key'
    }
    subscriptionRequired: false
    type: 'http'
    value: apiDefinition
  }
}

resource APIPolicy 'Microsoft.ApiManagement/service/apis/policies@2021-12-01-preview' = {
  parent: api
  name: 'policy'
  properties: {
    value: loadTextContent('../apim-streamable-mcp/empty_policy.xml')
    format: 'rawxml'
  }
}
