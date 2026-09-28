param aiFoundryAccountName string
param apimResourceId string

var apimServiceName = split(apimResourceId, '/')[8]

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimServiceName
}

// Foundry's gateway registration creates an account-named backend marker.
// Account APIs keep using the shared per-model policy and do not route through
// this backend directly.
resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: toLower(aiFoundryAccountName)
  properties: {
    protocol: 'http'
    url: 'https://${aiFoundryAccountName}.services.ai.azure.com/'
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://ai.azure.com/'
      }
    }
    tls: {
      validateCertificateChain: false
      validateCertificateName: false
    }
  }
}

output foundryBackendName string = foundryBackend.name
