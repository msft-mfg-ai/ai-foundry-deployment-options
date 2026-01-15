// https://github.com/Azure/bicep-registry-modules/blob/main/avm/ptn/azd/monitoring/README.md

param location string
param tags object = {}
param logAnalyticsWorkspaceName string
param applicationInsightsName string

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.2.1' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
    applicationInsightsDashboardName: null
    location: location
    tags: tags
  }
}

output MONITORING_LOG_ANALYTICS_ID string = monitoring.outputs.logAnalyticsWorkspaceResourceId
output MONITORING_APP_INSIGHTS_ID string = monitoring.outputs.applicationInsightsResourceId
output MONITORING_APP_INSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output MONITORING_APP_INSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output MONITORING_LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.logAnalyticsWorkspaceName
