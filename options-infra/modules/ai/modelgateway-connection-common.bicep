/*
Common module for creating ModelGateway connections to Foundry projects.
This module handles the core connection logic and can be reused across different ModelGateway connection samples.

AuthType / Category mapping (set automatically based on `authType`):
  - ApiKey                 → category=ModelGateway (Azure rejects PMI for this category)
  - OAuth2                 → category=ModelGateway with client credentials
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

@allowed(['ApiKey', 'OAuth2', 'ProjectManagedIdentity'])
param authType string = 'ApiKey'
param isSharedToAll bool = false

// Audience for ProjectManagedIdentity bearer token (ignored under ApiKey).
param audience string = 'https://cognitiveservices.azure.com'

// API key for the gateway endpoint (only used when authType=ApiKey).
@secure()
param apiKey string = ''

@description('OAuth2 client ID. Required when authType is OAuth2.')
param clientId string = ''

@secure()
@description('OAuth2 client secret. Required when authType is OAuth2.')
param clientSecret string = ''

@description('OAuth2 token endpoint. Required when authType is OAuth2.')
param tokenUrl string = ''

@description('OAuth2 scopes requested by Foundry.')
param scopes string[] = []

// ModelGateway-specific metadata (passed through from parent template)
param metadata object

// Category is derived from authType (see header comment).
var category = authType == 'ProjectManagedIdentity' ? 'ApiManagement' : 'ModelGateway'
var missingOAuthParams = concat(
  empty(clientId) ? ['clientId'] : [],
  empty(clientSecret) ? ['clientSecret'] : [],
  empty(tokenUrl) ? ['tokenUrl'] : [],
  empty(scopes) ? ['scopes'] : []
)
var validatedOAuthClientId = authType != 'OAuth2' || empty(missingOAuthParams)
  ? clientId
  : fail('OAuth2 ModelGateway connection is missing required parameters: ${join(missingOAuthParams, ', ')}.')

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
// OAuth2 path → category=ModelGateway, client credentials supplied
// ---------------------------------------------------------------------------
resource connectionOAuth2 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (empty(aiFoundryProjectName) && authType == 'OAuth2') {
  name: connectionName
  parent: aiFoundry
  properties: any({
    category: 'ModelGateway'
    target: targetUrl
    authType: 'OAuth2'
    isSharedToAll: isSharedToAll
    credentials: {
      clientId: validatedOAuthClientId
      clientSecret: clientSecret
    }
    tokenUrl: tokenUrl
    scopes: scopes
    metadata: metadata
  })
}

resource connectionProjectOAuth2 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(aiFoundryProjectName) && authType == 'OAuth2') {
  name: connectionName
  parent: aiFoundryProject
  properties: any({
    category: 'ModelGateway'
    target: targetUrl
    authType: 'OAuth2'
    isSharedToAll: isSharedToAll
    credentials: {
      clientId: validatedOAuthClientId
      clientSecret: clientSecret
    }
    tokenUrl: tokenUrl
    scopes: scopes
    metadata: metadata
  })
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
  : authType == 'OAuth2'
    ? (empty(aiFoundryProjectName) ? connectionOAuth2.name : connectionProjectOAuth2.name)
    : (empty(aiFoundryProjectName) ? connectionApiKey.name : connectionProjectApiKey.name)
output connectionId string = authType == 'ProjectManagedIdentity'
  ? (empty(aiFoundryProjectName) ? connectionAad.id : connectionProjectAad.id)
  : authType == 'OAuth2'
    ? (empty(aiFoundryProjectName) ? connectionOAuth2.id : connectionProjectOAuth2.id)
    : (empty(aiFoundryProjectName) ? connectionApiKey.id : connectionProjectApiKey.id)
output targetUrl string = targetUrl
output authType string = authType
output category string = category
output metadata object = metadata
