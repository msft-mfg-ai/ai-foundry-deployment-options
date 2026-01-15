param appInsightsName string
param foundryName string

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
  scope: resourceGroup()
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
  scope: resourceGroup()
}

// Creates the Azure Foundry connection Application Insights
resource connection 'Microsoft.CognitiveServices/accounts/connections@2025-06-01' = {
  name: 'applicationInsights'
  parent: foundry
  properties: {
    category: 'AppInsights'
    //group: 'ServicesAndApps'  // read-only...
    target: appInsights.id
    authType: 'ApiKey'
    isSharedToAll: true
    //isDefault: true  // not valid property
    credentials: {
      key: appInsights.properties.InstrumentationKey
    }
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsights.id
    }
  }
  dependsOn: [
    foundry
  ]
}
