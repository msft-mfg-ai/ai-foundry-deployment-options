// Project module — creates a Foundry project with connections and optional capability host
// Adapted from modules/ai/ai-project.bicep (self-contained, no external module refs)

param foundry_name string
param location string
param project_name string
param project_description string
param display_name string
param managedIdentityResourceId string = ''
param tags object = {}

param aiSearchName string = ''
param aiSearchServiceResourceGroupName string = ''
param aiSearchServiceSubscriptionId string = ''

param cosmosDBName string = ''
param cosmosDBSubscriptionId string = ''
param cosmosDBResourceGroupName string = ''

param azureStorageName string = ''
param azureStorageSubscriptionId string = ''
param azureStorageResourceGroupName string = ''

param createAccountCapabilityHost bool = false
param appInsightsResourceId string?

// -- App Insights ref --
var insightsParts string[] = split(appInsightsResourceId ?? '', '/')
var appInsightsName = length(insightsParts) > 0 ? insightsParts[length(insightsParts) - 1] : ''
var appInsightsResourceGroupName = length(insightsParts) > 4 ? insightsParts[4] : ''
var appInsightsSubscriptionId = length(insightsParts) > 2 ? insightsParts[2] : ''

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsResourceId)) {
  name: appInsightsName
  scope: resourceGroup(appInsightsSubscriptionId, appInsightsResourceGroupName)
}

// -- Managed identity ref --
var identityParts = split(managedIdentityResourceId, '/')
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(managedIdentityName)) {
  name: managedIdentityName
}

// -- Existing dependent resources --
#disable-next-line BCP081
resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundry_name
  scope: resourceGroup()
}

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (!empty(aiSearchName)) {
  name: aiSearchName
  scope: resourceGroup(aiSearchServiceSubscriptionId, aiSearchServiceResourceGroupName)
}
resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = if (!empty(cosmosDBName)) {
  name: cosmosDBName
  scope: resourceGroup(cosmosDBSubscriptionId, cosmosDBResourceGroupName)
}
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (!empty(azureStorageName)) {
  name: azureStorageName
  scope: resourceGroup(azureStorageSubscriptionId, azureStorageResourceGroupName)
}

// -- Project --
#disable-next-line BCP081
resource foundry_project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: foundry
  name: project_name
  tags: tags
  location: location
  identity: !empty(managedIdentityResourceId)
    ? {
        type: 'UserAssigned'
        userAssignedIdentities: {
          '${managedIdentityResourceId}': {}
        }
      }
    : {
        type: 'SystemAssigned'
      }
  properties: {
    description: project_description
    displayName: display_name
  }

  resource connection 'connections@2025-04-01-preview' = if (!empty(appInsightsName)) {
    name: 'applicationInsights-for-${project_name}'
    properties: {
      category: 'AppInsights'
      target: appInsights.id
      authType: 'ApiKey'
      isSharedToAll: false
      credentials: {
        key: appInsights!.properties.InstrumentationKey
      }
      metadata: {
        ApiType: 'Azure'
        ResourceId: appInsights.id
      }
    }
  }
}

// -- Connections --
resource project_connection_cosmosdb_account 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(cosmosDBName)) {
  name: '${cosmosDBName}-for-${project_name}'
  parent: foundry_project
  properties: {
    category: 'CosmosDB'
    target: cosmosDBAccount!.properties.documentEndpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmosDBAccount.id
      location: cosmosDBAccount!.location
    }
  }
}

resource project_connection_azure_storage 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(azureStorageName)) {
  name: '${azureStorageName}-for-${project_name}'
  parent: foundry_project
  properties: {
    category: 'AzureStorageAccount'
    target: storageAccount!.properties.primaryEndpoints.blob
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: storageAccount.id
      location: storageAccount!.location
    }
  }
}

resource project_connection_azureai_search 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!empty(aiSearchName)) {
  name: '${aiSearchName}-for-${project_name}'
  parent: foundry_project
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearchName}.search.windows.net'
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchService.id
      location: searchService!.location
    }
  }
}

// -- Capability Host --
@onlyIfNotExists()
resource accountCapabilityHost 'Microsoft.CognitiveServices/accounts/capabilityHosts@2025-04-01-preview' = if (createAccountCapabilityHost) {
  name: 'capHost'
  parent: foundry
  properties: {
    capabilityHostKind: 'Agents'
  }
  dependsOn: [
    foundry_project
    project_connection_cosmosdb_account
    project_connection_azure_storage
    project_connection_azureai_search
  ]
}

// -- Outputs --
output FOUNDRY_PROJECT_NAME string = foundry_project.name
output FOUNDRY_PROJECT_ID string = foundry_project.id
output FOUNDRY_PROJECT_CONNECTION_STRING string = 'https://${foundry_name}.services.ai.azure.com/api/projects/${project_name}'
output FOUNDRY_PROJECT_PRINCIPAL_ID string = empty(managedIdentityResourceId)
  ? foundry_project.identity.principalId
  : identity!.properties.principalId
