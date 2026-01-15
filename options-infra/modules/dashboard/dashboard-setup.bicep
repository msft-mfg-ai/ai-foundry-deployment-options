// Main Bicep deployment for APIM Token Usage Dashboard
// Deploys Azure Dashboard and Workbook for monitoring LLM token consumption

// ------------------
//    PARAMETERS
// ------------------

@description('Name of the existing Log Analytics workspace')
param logAnalyticsWorkspaceName string

@description('Location for the dashboard (defaults to resource group location)')
param location string = resourceGroup().location

@description('Dashboard display name')
param dashboardDisplayName string = 'APIM Token Usage Dashboard'

var params_are_valid = empty(logAnalyticsWorkspaceName)
  ? fail('LOG_ANALYTICS_WORKSPACE_NAME environment variable must be set')
  : true

// ------------------
//    EXISTING RESOURCES
// ------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

// ------------------
//    MODULES
// ------------------

module dashboard 'dashboard.bicep' = {
  name: 'tokenUsageDashboard'
  params: {
    location: location
    dashboardDisplayName: dashboardDisplayName
    logAnalyticsWorkspaceId: logAnalytics.id
    logAnalyticsWorkspaceName: logAnalytics.name
  }
}

module workbook 'workbook.bicep' = {
  name: 'tokenUsageWorkbook'
  params: {
    location: location
    workbookDisplayName: 'APIM Token Usage Workbook'
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

module savedQueries 'saved-queries.bicep' = {
  name: 'savedQueries'
  params: {
    logAnalyticsWorkspaceId: logAnalytics.id
  }
}

// ------------------
//    OUTPUTS
// ------------------

output dashboardId string = dashboard.outputs.dashboardId
output dashboardUrl string = 'https://portal.azure.com/#@/dashboard/arm${dashboard.outputs.dashboardId}'
output workbookId string = workbook.outputs.workbookId
output params_are_valid_output bool = params_are_valid
