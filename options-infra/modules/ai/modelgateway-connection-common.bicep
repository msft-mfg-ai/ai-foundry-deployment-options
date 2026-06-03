/*
Common module for creating ModelGateway connections to Foundry projects.
This module handles the core connection logic and can be reused across different ModelGateway connection samples.

AuthType / Category mapping (set automatically based on `authType`):
  - ApiKey                 → category=ModelGateway (Azure rejects PMI for this category)
  - ProjectManagedIdentity → category=ApiManagement + audience set
    (ApiManagement category is required for the Foundry portal BYOM page to
     render `metadata.models` — see agents_anthropic/foundry-byom-ui-findings.md)
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

@allowed(['ApiKey', 'ProjectManagedIdentity'])
param authType string = 'ApiKey'
param isSharedToAll bool = false

// Audience for ProjectManagedIdentity bearer token (ignored under ApiKey).
param audience string = 'https://cognitiveservices.azure.com'

// API key for the gateway endpoint (only used when authType=ApiKey).
@secure()
param apiKey string = ''

// ModelGateway-specific metadata (passed through from parent template)
param metadata object

// Category is derived from authType (see header comment).
var category = authType == 'ProjectManagedIdentity' ? 'ApiManagement' : 'ModelGateway'

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

resource aiFoundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = if (!empty(aiFoundryProjectName)) {
  name: aiFoundryProjectName!
  parent: aiFoundry
}

// ---------------------------------------------------------------------------
// ApiKey path → category=ModelGateway, credentials.key supplied
// ---------------------------------------------------------------------------
resource connectionApiKey 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (empty(aiFoundryProjectName) && authType == 'ApiKey') {
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

resource connectionProjectApiKey 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(aiFoundryProjectName) && authType == 'ApiKey') {
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

// ---------------------------------------------------------------------------
// PMI path → category=ApiManagement, audience supplied, no credentials.
// Foundry's ModelGateway authenticates via the project MI bearer token.
// ---------------------------------------------------------------------------
resource connectionAad 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (empty(aiFoundryProjectName) && authType == 'ProjectManagedIdentity') {
  name: connectionName
  parent: aiFoundry
  properties: {
    category: 'ApiManagement'
    target: targetUrl
    authType: 'ProjectManagedIdentity'
    audience: audience
    isSharedToAll: isSharedToAll
    metadata: metadata
  }
}

resource connectionProjectAad 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(aiFoundryProjectName) && authType == 'ProjectManagedIdentity') {
  name: connectionName
  parent: aiFoundryProject
  properties: {
    category: 'ApiManagement'
    target: targetUrl
    authType: 'ProjectManagedIdentity'
    audience: audience
    isSharedToAll: isSharedToAll
    metadata: metadata
  }
}

// Outputs — pick the resource that actually got created
output connectionName string = authType == 'ProjectManagedIdentity'
  ? (empty(aiFoundryProjectName) ? connectionAad.name : connectionProjectAad.name)
  : (empty(aiFoundryProjectName) ? connectionApiKey.name : connectionProjectApiKey.name)
output connectionId string = authType == 'ProjectManagedIdentity'
  ? (empty(aiFoundryProjectName) ? connectionAad.id : connectionProjectAad.id)
  : (empty(aiFoundryProjectName) ? connectionApiKey.id : connectionProjectApiKey.id)
output targetUrl string = targetUrl
output authType string = authType
output category string = category
output metadata object = metadata
