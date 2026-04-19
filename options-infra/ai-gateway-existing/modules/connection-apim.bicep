// APIM connection module — creates a static connection from Foundry project to existing APIM
// Adapted from modules/ai/connection-project.bicep

param aiFoundryName string
param aiFoundryProjectName string
param connectionName string

param category string = 'ApiManagement'
@description('The target URL for the APIM connection')
param target string
@allowed(['ProjectManagedIdentity', 'ApiKey'])
param authType string
param audience string = 'https://cognitiveservices.azure.com'
param isSharedToAll bool = false
param metadata object = {}
@secure()
param subscriptionKey string?

resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: aiFoundryProjectName
  parent: aiFoundry
}

resource connectionApiKeyProject 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (authType == 'ApiKey') {
  name: connectionName
  parent: aiProject
  properties: {
    category: category
    target: target
    authType: authType
    isSharedToAll: isSharedToAll
    credentials: {
      key: subscriptionKey!
    }
    metadata: metadata
  }
}

resource connectionAADProject 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (authType == 'ProjectManagedIdentity') {
  name: connectionName
  parent: aiProject
  properties: {
    category: category
    target: target
    authType: authType
    audience: audience
    isSharedToAll: isSharedToAll
    metadata: metadata
  }
}

output connectionName string = authType == 'ProjectManagedIdentity' ? connectionAADProject.name : connectionApiKeyProject.name
output connectionId string = authType == 'ProjectManagedIdentity' ? connectionAADProject.id : connectionApiKeyProject.id
