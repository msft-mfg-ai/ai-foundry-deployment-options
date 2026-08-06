param appInsightsName string
param principalId string
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param principalType string = 'ServicePrincipal'

// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#log-analytics-reader
var logAnalyticsReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '73c42c96-874c-492b-b04d-ab87d138a893'
)

// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#privileged-monitoring-data-reader
// Required so the Foundry project MI can read GenAI prompt/response content used by evaluation.
var privilegedMonitoringDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'dbc9c667-e97f-4491-aee6-90b9cf960190'
)

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
  scope: resourceGroup()
}

resource logAnalyticsReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(appInsights.id, principalId, logAnalyticsReaderRoleId)
  properties: {
    principalId: principalId
    roleDefinitionId: logAnalyticsReaderRoleId
    principalType: principalType
  }
}

resource privilegedMonitoringDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: appInsights
  name: guid(appInsights.id, principalId, privilegedMonitoringDataReaderRoleId)
  properties: {
    principalId: principalId
    roleDefinitionId: privilegedMonitoringDataReaderRoleId
    principalType: principalType
  }
}
