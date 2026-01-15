// Azure Portal Dashboard for APIM Token Usage Monitoring
// Based on AI-Gateway FinOps Framework patterns
// Layout derived from exported Azure Portal dashboard JSON

@description('Location for the dashboard')
param location string

@description('Dashboard display name')
param dashboardDisplayName string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Log Analytics Workspace name')
param logAnalyticsWorkspaceName string

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-token-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// KQL Queries for dashboard tiles
var kqlTodayStats = '''
ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= startofday(now())
| summarize
    TodayTokens = sum(TotalTokens),
    TodayRequests = count(),
    AvgTokensPerRequest = avg(TotalTokens)
'''

var kqlMonthStats = '''
ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= startofmonth(now())
| summarize
    MonthTokens = sum(TotalTokens),
    MonthRequests = count(),
    UniqueSubscriptions = dcount(CorrelationId)
'''

var kqlTokenUsageOverTime = '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
let llmLogsWithSubscriptionId = llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| project
    TimeGenerated,
    SubscriptionName = ApimSubscriptionId,
    TotalTokens;
llmLogsWithSubscriptionId
| summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1h), SubscriptionName
| order by TimeGenerated asc
'''

var kqlTopConsumers = '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= ago(30d);
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize TotalTokens = sum(TotalTokens), Requests = count() by SubscriptionId = ApimSubscriptionId
| top 10 by TotalTokens desc
| extend Percentage = round(TotalTokens * 100.0 / toscalar(
    ApiManagementGatewayLlmLog
    | where DeploymentName != ''
    | where TimeGenerated >= ago(30d)
    | summarize sum(TotalTokens)
), 1)
'''

var kqlDailyUsageSummary = '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
let llmLogsWithSubscriptionId = llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| project
    TimeGenerated,
    SubscriptionName = ApimSubscriptionId,
    PromptTokens,
    CompletionTokens,
    TotalTokens;
llmLogsWithSubscriptionId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = count()
by bin(TimeGenerated, 1d)
| order by TimeGenerated desc
'''

var kqlUsageBySubscription = '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
let llmLogsWithSubscriptionId = llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| project
    SubscriptionName = ApimSubscriptionId,
    DeploymentName,
    PromptTokens,
    CompletionTokens,
    TotalTokens;
llmLogsWithSubscriptionId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = count()
by SubscriptionName, DeploymentName
| order by TotalTokens desc
'''

var kqlModelUsage = '''
ApiManagementGatewayLlmLog
| where DeploymentName != ''
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = count()
by DeploymentName, ModelName
| order by TotalTokens desc
'''

var kqlTotalTokensPerSubscription = '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = count()
by SubscriptionId = ApimSubscriptionId
| order by TotalTokens desc
'''

// ------------------
//    RESOURCES
// ------------------

resource dashboard 'Microsoft.Portal/dashboards@2022-12-01-preview' = {
  name: dashboardName
  location: location
  tags: {
    'hidden-title': dashboardDisplayName
  }
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          // Title/Header - Row 0-1, full width
          {
            position: {
              x: 0
              y: 0
              colSpan: 12
              rowSpan: 2
            }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  content: '# 🤖 APIM Token Usage Dashboard\n\nMonitor LLM token consumption across APIM subscriptions. Data sourced from `ApiManagementGatewayLlmLog` following the [AI-Gateway FinOps Framework](https://github.com/Azure-Samples/AI-Gateway).'
                  title: 'APIM Token Usage Dashboard'
                  subtitle: ''
                  markdownSource: 1
                }
              }
            }
          }
          // Today's Stats - Row 2-3, left half
          {
            position: {
              x: 0
              y: 2
              colSpan: 6
              rowSpan: 2
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P1D', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'PartId', value: 'today-stats', isOptional: true }
                { name: 'PartTitle', value: '📊 Today\'s Usage', isOptional: true }
                { name: 'PartSubTitle', value: logAnalyticsWorkspaceName, isOptional: true }
                { name: 'Query', value: kqlTodayStats, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Month Stats - Row 2-3, right half
          {
            position: {
              x: 6
              y: 2
              colSpan: 6
              rowSpan: 2
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'month-stats', isOptional: true }
                { name: 'PartTitle', value: '📅 This Month', isOptional: true }
                { name: 'PartSubTitle', value: logAnalyticsWorkspaceName, isOptional: true }
                { name: 'Query', value: kqlMonthStats, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Token Usage Over Time Chart - Row 4-8, wide (17 cols for chart)
          {
            position: {
              x: 0
              y: 4
              colSpan: 17
              rowSpan: 5
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'usage-over-time', isOptional: true }
                { name: 'PartTitle', value: '📈 Token Usage Over Time', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly token consumption by subscription', isOptional: true }
                { name: 'Query', value: kqlTokenUsageOverTime, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {
                content: {
                  Query: '${kqlTokenUsageOverTime}\n'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'StackedColumn'
                  Dimensions: {
                    xAxis: { name: 'TimeGenerated', type: 'datetime' }
                    yAxis: [ { name: 'TotalTokens', type: 'long' } ]
                    splitBy: [ { name: 'SubscriptionName', type: 'string' } ]
                    aggregation: 'Sum'
                  }
                  LegendOptions: { isEnabled: true, position: 'Bottom' }
                }
              }
            }
          }
          // Top Consumers - Row 10-12, left
          {
            position: {
              x: 0
              y: 10
              colSpan: 8
              rowSpan: 3
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'top-consumers', isOptional: true }
                { name: 'PartTitle', value: '🏆 Top Token Consumers', isOptional: true }
                { name: 'PartSubTitle', value: 'Last 30 days', isOptional: true }
                { name: 'Query', value: kqlTopConsumers, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Daily Summary - Row 10-12, right
          {
            position: {
              x: 8
              y: 10
              colSpan: 9
              rowSpan: 3
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'daily-summary', isOptional: true }
                { name: 'PartTitle', value: '📊 Daily Usage Summary', isOptional: true }
                { name: 'PartSubTitle', value: 'Prompt, Completion, and Total tokens per day', isOptional: true }
                { name: 'Query', value: kqlDailyUsageSummary, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Usage by Subscription & Model - Row 13-16, full width
          {
            position: {
              x: 0
              y: 13
              colSpan: 12
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'usage-by-subscription', isOptional: true }
                { name: 'PartTitle', value: '📋 Usage by Subscription & Model', isOptional: true }
                { name: 'PartSubTitle', value: 'Detailed breakdown', isOptional: true }
                { name: 'Query', value: kqlUsageBySubscription, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Usage by Model - Row 17-19, full width
          {
            position: {
              x: 0
              y: 17
              colSpan: 12
              rowSpan: 3
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'model-usage', isOptional: true }
                { name: 'PartTitle', value: '🧠 Usage by Model', isOptional: true }
                { name: 'PartSubTitle', value: 'Token consumption per deployment', isOptional: true }
                { name: 'Query', value: kqlModelUsage, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
          // Total Tokens per Subscription - Row 20-24, full width
          {
            position: {
              x: 0
              y: 20
              colSpan: 12
              rowSpan: 5
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'total-tokens-subscription', isOptional: true }
                { name: 'PartTitle', value: '💰 Total Tokens per Subscription', isOptional: true }
                { name: 'PartSubTitle', value: 'All-time token usage by subscription', isOptional: true }
                { name: 'Query', value: kqlTotalTokensPerSubscription, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
                { name: 'resourceTypeMode', isOptional: true }
                { name: 'ComponentId', isOptional: true }
                { name: 'DashboardId', isOptional: true }
                { name: 'DraftRequestParameters', isOptional: true }
                { name: 'SpecificChart', isOptional: true }
                { name: 'Dimensions', isOptional: true }
                { name: 'LegendOptions', isOptional: true }
                { name: 'IsQueryContainTimeRange', isOptional: true }
              ]
              settings: {}
            }
          }
        ]
      }
    ]
    metadata: {
      model: {
        timeRange: {
          value: {
            relative: {
              duration: 24
              timeUnit: 1
            }
          }
          type: 'MsPortalFx.Composition.Configuration.ValueTypes.TimeRange'
        }
        filterLocale: {
          value: 'en-us'
        }
        filters: {
          value: {
            MsPortalFx_TimeRange: {
              model: {
                format: 'utc'
                granularity: 'auto'
                relative: '7d'
              }
              displayCache: {
                name: 'UTC Time'
                value: 'Past 7 days'
              }
            }
          }
        }
      }
    }
  }
}

// ------------------
//    OUTPUTS
// ------------------

output dashboardId string = dashboard.id
output dashboardName string = dashboard.name
