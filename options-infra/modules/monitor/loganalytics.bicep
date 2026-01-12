param newLogAnalyticsName string = ''
param newApplicationInsightsName string = ''

param existingLogAnalyticsName string = ''
param existingLogAnalyticsRgName string = resourceGroup().name
param existingLogAnalyticsSubId string = subscription().subscriptionId
param existingApplicationInsightsName string = ''
param existingApplicationInsightsRgName string = resourceGroup().name
param existingApplicationInsightsSubId string = subscription().subscriptionId
param managedIdentityResourceId string = ''

param location string = resourceGroup().location
param tags object = {}
param azureMonitorPrivateLinkScopeName string = ''
param azureMonitorPrivateLinkScopeResourceGroupName string = ''
param privateEndpointSubnetId string = ''
param privateEndpointName string = ''
param publicNetworkAccessForIngestion string = 'Enabled'
param publicNetworkAccessForQuery string = 'Enabled'

var useExistingLogAnalytics = !empty(existingLogAnalyticsName)
var useExistingAppInsights = !empty(existingApplicationInsightsName)

var monitoringMetricsPublisherId = '3913510d-42f4-4e42-8a64-420c390055eb'

// --------------------------------------------------------------------------------------------------------------
// split managed identity resource ID to get the name
var identityParts = split(managedIdentityResourceId, '/')
// get the name of the managed identity
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(managedIdentityResourceId)) {
  name: managedIdentityName
}

// -------------------------------------------------------
resource existingLogAnalyticsResource 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (useExistingLogAnalytics) {
  name: existingLogAnalyticsName
  scope: resourceGroup(existingLogAnalyticsSubId, existingLogAnalyticsRgName)
}

resource existingApplicationInsightsResource 'Microsoft.Insights/components@2020-02-02' existing = if (useExistingAppInsights) {
  name: existingApplicationInsightsName
  scope: resourceGroup(existingApplicationInsightsSubId, existingApplicationInsightsRgName)
}

resource newLogAnalyticsResource 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (!useExistingLogAnalytics) {
  name: newLogAnalyticsName
  location: location
  tags: tags
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
      // this is required for ACA logging
      disableLocalAuth: false
    }
    sku: {
      name: 'PerGB2018'
    }
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
  })
}

resource newApplicationInsightsResource 'Microsoft.Insights/components@2020-02-02' = if (!useExistingAppInsights) {
  name: newApplicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: newLogAnalyticsResource.id
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
    // enable local auth for APIM integration
    DisableLocalAuth: false
  }
}

resource azureMonitorPrivateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' existing = if (!empty(azureMonitorPrivateLinkScopeName)) {
  name: azureMonitorPrivateLinkScopeName
  scope: resourceGroup(azureMonitorPrivateLinkScopeResourceGroupName)
}

module azureMonitorPrivateLinkScopePrivateEndpoint '../networking/private-endpoint.bicep' = if (!empty(privateEndpointSubnetId)) {
  name: 'azure-monitor-private-link-scope-private-endpoint'
  params: {
    privateEndpointName: privateEndpointName
    groupIds: ['azuremonitor']
    targetResourceId: azureMonitorPrivateLinkScope.id
    subnetId: privateEndpointSubnetId
  }
}
 
// do not assign role if using existing Application Insights
// resource roleAssignmentAppInsights 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(managedIdentityId) && useExistingAppInsights) {
//   name: guid(subscription().id, existingApplicationInsightsResource.id, identity.id, 'Monitoring Metrics Publisher')
//   scope: existingApplicationInsightsResource
//   properties: {
//     roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherId)
//     principalId: identity!.properties.principalId
//     principalType: 'ServicePrincipal'
//   }
// }

resource roleAssignmentAppInsightsNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(managedIdentityResourceId) && !useExistingAppInsights) {
  name: guid(subscription().id, newApplicationInsightsResource.id, identity.id, 'Monitoring Metrics Publisher')
  scope: newApplicationInsightsResource
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherId)
    principalId: identity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}


output LOG_ANALYTICS_WORKSPACE_RESOURCE_ID string = useExistingLogAnalytics
  ? existingLogAnalyticsResource.id
  : newLogAnalyticsResource.id
output LOG_ANALYTICS_WORKSPACE_NAME string = useExistingLogAnalytics
  ? existingLogAnalyticsResource.name
  : newLogAnalyticsResource.name
output APPLICATION_INSIGHTS_RESOURCE_ID string = useExistingAppInsights
  ? existingApplicationInsightsResource.id
  : newApplicationInsightsResource.id
output APPLICATION_INSIGHTS_NAME string = useExistingAppInsights
  ? existingApplicationInsightsResource.name
  : newApplicationInsightsResource.name
output APPLICATION_INSIGHTS_CONNECTION_STRING string = useExistingAppInsights
  ? existingApplicationInsightsResource.?properties.ConnectionString ?? ''
  : newApplicationInsightsResource.?properties.ConnectionString ?? ''
output APPLICATION_INSIGHTS_INSTRUMENTATION_KEY string = useExistingAppInsights
  ? existingApplicationInsightsResource.?properties.InstrumentationKey ?? ''
  : newApplicationInsightsResource.?properties.InstrumentationKey ?? ''
