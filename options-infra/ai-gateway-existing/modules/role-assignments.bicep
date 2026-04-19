// Role assignments for Foundry project identity to dependent resources
// Assigns the necessary RBAC roles so the project can access Cosmos DB, Storage, and AI Search

@description('Principal ID of the Foundry project managed identity')
param principalId string

// -- Cosmos DB ----------------------------------------------------------------
@description('Name of the Cosmos DB account')
param cosmosDBName string = ''

resource cosmosDBAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = if (!empty(cosmosDBName)) {
  name: cosmosDBName
  scope: resourceGroup()
}

// Cosmos DB Operator (ARM-level operations)
resource cosmosDBOperatorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = if (!empty(cosmosDBName)) {
  name: '230815da-be43-4aae-9cb4-875f7bd000aa'
  scope: resourceGroup()
}

resource cosmosDBOperatorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(cosmosDBName)) {
  scope: cosmosDBAccount
  name: guid(principalId, cosmosDBOperatorRole.id, cosmosDBAccount.id)
  properties: {
    principalId: principalId
    roleDefinitionId: cosmosDBOperatorRole.id
    principalType: 'ServicePrincipal'
  }
}

// Cosmos DB Built-in Data Contributor (data-plane SQL role)
var cosmosDataContributorRoleId = resourceId('Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions', cosmosDBName, '00000000-0000-0000-0000-000000000002')

resource cosmosDataContributorAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-05-15' = if (!empty(cosmosDBName)) {
  parent: cosmosDBAccount
  name: guid(principalId, cosmosDataContributorRoleId, cosmosDBAccount.id)
  properties: {
    principalId: principalId
    roleDefinitionId: cosmosDataContributorRoleId
    scope: cosmosDBAccount.id
  }
}

// -- Storage Account ----------------------------------------------------------
@description('Name of the Storage Account')
param azureStorageName string = ''

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (!empty(azureStorageName)) {
  name: azureStorageName
  scope: resourceGroup()
}

// Storage Blob Data Contributor
resource storageBlobDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = if (!empty(azureStorageName)) {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  scope: resourceGroup()
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(azureStorageName)) {
  scope: storageAccount
  name: guid(principalId, storageBlobDataContributorRole.id, storageAccount.id)
  properties: {
    principalId: principalId
    roleDefinitionId: storageBlobDataContributorRole.id
    principalType: 'ServicePrincipal'
  }
}

// -- AI Search ----------------------------------------------------------------
@description('Name of the AI Search service')
param aiSearchName string = ''

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' existing = if (!empty(aiSearchName)) {
  name: aiSearchName
  scope: resourceGroup()
}

// Search Index Data Contributor
resource searchIndexDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = if (!empty(aiSearchName)) {
  name: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  scope: resourceGroup()
}

resource searchIndexDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aiSearchName)) {
  scope: searchService
  name: guid(principalId, searchIndexDataContributorRole.id, searchService.id)
  properties: {
    principalId: principalId
    roleDefinitionId: searchIndexDataContributorRole.id
    principalType: 'ServicePrincipal'
  }
}

// Search Service Contributor
resource searchServiceContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = if (!empty(aiSearchName)) {
  name: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  scope: resourceGroup()
}

resource searchServiceContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(aiSearchName)) {
  scope: searchService
  name: guid(principalId, searchServiceContributorRole.id, searchService.id)
  properties: {
    principalId: principalId
    roleDefinitionId: searchServiceContributorRole.id
    principalType: 'ServicePrincipal'
  }
}
