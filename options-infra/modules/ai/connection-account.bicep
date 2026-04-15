/*
Common module for creating APIM connections to Foundry projects.
This module handles the core connection logic and can be reused across different APIM connection samples.
*/
// https://github.com/azure-ai-foundry/foundry-samples/blob/main/infrastructure/infrastructure-setup-bicep/01-connections/apim/connection-apim.bicep

// Project resource parameters
param aiFoundryName string
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

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

// Create the connection with ApiKey authentication
resource connectionApiKeyAccount 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (authType == 'ApiKey') {
  name: connectionName
  parent: aiFoundry
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

resource connectionAADAccount 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (authType == 'ProjectManagedIdentity') {
  name: connectionName
  parent: aiFoundry
  properties: {
    category: category
    target: target
    authType: authType
    audience: audience
    isSharedToAll: isSharedToAll
    metadata: metadata
  }
}

// Outputs (only from the created connection)
output connectionName string = authType == 'ProjectManagedIdentity' ? connectionAADAccount!.name : connectionApiKeyAccount.name
output connectionId string = authType == 'ProjectManagedIdentity' ? connectionAADAccount!.id : connectionApiKeyAccount.id
output targetUrl string = target
output authType string = authType
output metadata object = metadata
