// Simplified Log Analytics + App Insights module (no private endpoints)
param newLogAnalyticsName string = ''
param newApplicationInsightsName string = ''

param existingApplicationInsightsResourceId string = ''

param location string = resourceGroup().location
param tags object = {}
param managedIdentityResourceId string = ''

var useExistingAppInsights = !empty(existingApplicationInsightsResourceId)
var existingAppInsightsParts = split(existingApplicationInsightsResourceId, '/')
var existingAppInsightsName = useExistingAppInsights ? last(existingAppInsightsParts) : ''
var existingAppInsightsRgName = useExistingAppInsights ? existingAppInsightsParts[4] : ''
var existingAppInsightsSubId = useExistingAppInsights ? existingAppInsightsParts[2] : ''

var monitoringMetricsPublisherId = '3913510d-42f4-4e42-8a64-420c390055eb'

// split managed identity resource ID to get the name
var identityParts = split(managedIdentityResourceId, '/')
var managedIdentityName = length(identityParts) > 0 ? identityParts[length(identityParts) - 1] : ''

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-07-31-preview' existing = if (!empty(managedIdentityResourceId)) {
  name: managedIdentityName
}

resource existingApplicationInsightsResource 'Microsoft.Insights/components@2020-02-02' existing = if (useExistingAppInsights) {
  name: existingAppInsightsName
  scope: resourceGroup(existingAppInsightsSubId, existingAppInsightsRgName)
}

resource newLogAnalyticsResource 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (!useExistingAppInsights) {
  name: newLogAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      disableLocalAuth: false
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource newApplicationInsightsResource 'Microsoft.Insights/components@2020-02-02' = if (!useExistingAppInsights) {
  name: newApplicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: newLogAnalyticsResource.id
    DisableLocalAuth: false
  }
}

resource roleAssignmentAppInsightsNew 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(managedIdentityResourceId) && !useExistingAppInsights) {
  name: guid(subscription().id, newApplicationInsightsResource.id, identity.id, 'Monitoring Metrics Publisher')
  scope: newApplicationInsightsResource
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherId)
    principalId: identity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output APPLICATION_INSIGHTS_RESOURCE_ID string = useExistingAppInsights
  ? existingApplicationInsightsResource.id
  : newApplicationInsightsResource.id
output APPLICATION_INSIGHTS_NAME string = useExistingAppInsights
  ? existingApplicationInsightsResource.name
  : newApplicationInsightsResource.name
output APPLICATION_INSIGHTS_INSTRUMENTATION_KEY string = useExistingAppInsights
  ? existingApplicationInsightsResource.?properties.InstrumentationKey ?? ''
  : newApplicationInsightsResource.?properties.InstrumentationKey ?? ''
output LOG_ANALYTICS_WORKSPACE_NAME string = useExistingAppInsights ? '' : newLogAnalyticsResource.name
