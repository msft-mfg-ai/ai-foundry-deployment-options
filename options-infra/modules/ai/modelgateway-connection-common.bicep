/*
Common module for creating ModelGateway connections to Azure AI Foundry projects.
This module handles the core connection logic and can be reused across different ModelGateway connection samples.
ModelGateway connections support ApiKey authentication.
*/

@export()
type AuthConfigType = {
  type: null | 'api_key'
  name: null | 'Authorization'
  format: string
}

// Project resource parameters
param aiFoundryName string
param aiFoundryProjectName string?
param connectionName string

// ModelGateway target configuration
param targetUrl string

// Connection configuration (ModelGateway only supports ApiKey)
param authType string = 'ApiKey'
param isSharedToAll bool = false

// API key for the ModelGateway endpoint
@secure()
param apiKey string

// ModelGateway-specific metadata (passed through from parent template)
param metadata object

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

resource aiFoundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = if (!empty(aiFoundryProjectName)) {
  name: aiFoundryProjectName!
  parent: aiFoundry
}

// Create the ModelGateway connection with ApiKey authentication
resource connectionApiKey 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (empty(aiFoundryProjectName)) {
  name: connectionName
  parent: aiFoundry
  properties: {
    category: 'ModelGateway'
    target: targetUrl
    authType: 'ApiKey'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apiKey
    }
    metadata: metadata
  }
}

resource connectionProjectApiKey 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(aiFoundryProjectName)) {
  name: connectionName
  parent: aiFoundryProject
  properties: {
    category: 'ModelGateway'
    target: targetUrl
    authType: 'ApiKey'
    isSharedToAll: isSharedToAll
    credentials: {
      key: apiKey
    }
    metadata: metadata
  }
}

// Outputs
output connectionName string = connectionApiKey.name
output connectionId string = connectionApiKey.id
output targetUrl string = targetUrl
output authType string = authType
output metadata object = metadata
