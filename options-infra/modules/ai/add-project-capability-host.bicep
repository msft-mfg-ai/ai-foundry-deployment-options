param cosmosDBConnection string = ''
param azureStorageConnection string = ''
param aiSearchConnection string = ''
param aiFoundryConnectionName string = ''
param projectName string
param accountName string
param projectCapHost string = 'projcaphost'

var threadStorageConnections = empty(cosmosDBConnection) ? [] : ['${cosmosDBConnection}']
var storageConnections = empty(azureStorageConnection) ? [] : ['${azureStorageConnection}']
var vectorStoreConnections = empty(aiSearchConnection) ? [] : ['${aiSearchConnection}']
var aiServicesConnections = empty(aiFoundryConnectionName) ? [] : ['${aiFoundryConnectionName}']

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
   name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  name: projectName
  parent: account
}

var settingsOptions = [
  { key: 'capabilityHostKind', value: 'Agents'}
  { key: 'threadStorageConnections', value: threadStorageConnections}
  { key: 'storageConnections', value: storageConnections}
  { key: 'vectorStoreConnections', value: vectorStoreConnections}
  { key: 'aiServicesConnections', value: aiServicesConnections}
]

// convert properties to an object but exclude empty properties
var propertiesObject = [for (item, key) in settingsOptions: (!empty(item.value) ? { '${item.key}': item.value }: {})]
var properties = reduce(propertiesObject, {}, (cur, next) => union(cur, next))

@onlyIfNotExists()
resource projectCapabilityHostStandard 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-10-01-preview' = {
  name: projectCapHost
  parent: project
  properties: properties
}

output AI_PROJECT_CAPABILITY_HOST_NAME string = projectCapHost
