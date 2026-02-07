// Azure Portal Dashboard for APIM Token Usage Monitoring
// Based on AI-Gateway FinOps Framework patterns
// Uses AppMetrics (Log Analytics) for token data with Project ID, and ApiManagementGatewayLlmLog for model usage

@description('Location for the dashboard')
param location string

@description('Dashboard display name')
param dashboardDisplayName string

@description('Application Insights resource ID for metrics queries')
param applicationInsightsId string

@description('Application Insights name')
param applicationInsightsName string

@description('Log Analytics Workspace resource ID for AppMetrics and gateway logs')
param logAnalyticsWorkspaceId string

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-token-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// KQL Queries for dashboard tiles
// Uses AppMetrics for project-based stats (has Project ID in Properties)
// Uses ApiManagementGatewayLlmLog joined with ApiManagementGatewayLogs for model usage by project
// The x-caller-name header is logged in RequestHeaders via API diagnostics configuration

var kqlTodayStats = '''
AppMetrics
| where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| where TimeGenerated >= startofday(now())
| summarize
    TodayPromptTokens = sumif(Sum, Name == "Prompt Tokens"),
    TodayCompletionTokens = sumif(Sum, Name == "Completion Tokens"),
    TodayTotalTokens = sumif(Sum, Name == "Total Tokens"),
    TodayRequests = countif(Name == "Total Tokens")
'''

var kqlMonthStats = '''
AppMetrics
| where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| where TimeGenerated >= startofmonth(now())
| extend CallerName = tostring(parse_json(Properties)["Caller Name"])
| summarize
    MonthTotalTokens = sumif(Sum, Name == "Total Tokens"),
    MonthRequests = countif(Name == "Total Tokens"),
    UniqueProjects = dcount(CallerName)
'''

// Token usage over time by Project - using AppMetrics which has Project ID
var kqlTokenUsageOverTime = '''
AppMetrics
| where Name == "Total Tokens"
| extend CallerName = tostring(parse_json(Properties)["Caller Name"])
| summarize TotalTokens = sum(Sum) by bin(TimeGenerated, 1h), CallerName
| order by TimeGenerated asc
'''

var kqlTopConsumers = '''
let totalTokens = toscalar(
    AppMetrics
    | where Name == "Total Tokens"
    | where TimeGenerated >= ago(30d)
    | summarize sum(Sum)
);
AppMetrics
| where Name == "Total Tokens"
| where TimeGenerated >= ago(30d)
| extend CallerName = tostring(parse_json(Properties)["Caller Name"])
| summarize TotalTokens = sum(Sum), Requests = dcount(OperationId) by CallerName
| top 10 by TotalTokens desc
| extend Percentage = round(TotalTokens * 100.0 / totalTokens, 1)
'''

var kqlDailyUsageSummary = '''
AppMetrics
| where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| extend CallerName = tostring(parse_json(Properties)["Caller Name"])
| summarize
    PromptTokens = sumif(Sum, Name == "Prompt Tokens"),
    CompletionTokens = sumif(Sum, Name == "Completion Tokens"),
    TotalTokens = sumif(Sum, Name == "Total Tokens"),
    Requests = countif(Name == "Total Tokens")
by bin(TimeGenerated, 1d), CallerName
| order by TimeGenerated desc
'''

var kqlModelUsage = '''
// Join LLM logs (has DeploymentName) with Gateway logs (has x-caller-name header)
let llmLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ""
| project TimeGenerated, DeploymentName, ModelName, PromptTokens, CompletionTokens, TotalTokens, CorrelationId;
let gatewayLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| project CorrelationId, CallerName;
llmLogs
| join kind=leftouter gatewayLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = dcount(CorrelationId)
by DeploymentName, ModelName
| order by TotalTokens desc
'''

// Model usage by project - answers "what models is each project using?"
var kqlModelUsageByProject = '''
// Join LLM logs (has DeploymentName) with Gateway logs (has x-caller-name header)
let llmLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ""
| project TimeGenerated, DeploymentName, ModelName, PromptTokens, CompletionTokens, TotalTokens, CorrelationId;
let gatewayLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| project CorrelationId, CallerName;
llmLogs
| join kind=leftouter gatewayLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = dcount(CorrelationId)
by CallerName, DeploymentName
| order by CallerName, TotalTokens desc
'''

var kqlTotalTokensPerProject = '''
AppMetrics
| where Name in ("Prompt Tokens", "Completion Tokens", "Total Tokens")
| extend CallerName = tostring(parse_json(Properties)["Caller Name"])
| summarize
    PromptTokens = sumif(Sum, Name == "Prompt Tokens"),
    CompletionTokens = sumif(Sum, Name == "Completion Tokens"),
    TotalTokens = sumif(Sum, Name == "Total Tokens"),
    Requests = countif(Name == "Total Tokens")
by CallerName
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
                  content: '# 🤖 APIM Token Usage Dashboard\n\nMonitor LLM token consumption by AI Foundry Project. Data sourced from `AppMetrics` (Project ID, token counts) and `ApiManagementGatewayLlmLog` (deployment/model details).'
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
                { name: 'PartSubTitle', value: applicationInsightsName, isOptional: true }
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
                { name: 'PartSubTitle', value: applicationInsightsName, isOptional: true }
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
                { name: 'PartTitle', value: '📈 Token Usage Over Time by Project', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly token consumption by project/subscription', isOptional: true }
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
                    splitBy: [ { name: 'CallerName', type: 'string' } ]
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
                { name: 'PartTitle', value: '🏆 Top Token Consumers by Project', isOptional: true }
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
                { name: 'PartTitle', value: '📊 Daily Usage by Project', isOptional: true }
                { name: 'PartSubTitle', value: 'Prompt, Completion, and Total tokens per day by project', isOptional: true }
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
          // Usage by Model - Row 13-15, full width
          {
            position: {
              x: 0
              y: 13
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
          // Model Usage by Project - Row 16-19, full width - answers "what models is each project using?"
          {
            position: {
              x: 0
              y: 16
              colSpan: 12
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'model-usage-by-project', isOptional: true }
                { name: 'PartTitle', value: '🔗 Models Used by Project', isOptional: true }
                { name: 'PartSubTitle', value: 'Which deployments/models each project is consuming', isOptional: true }
                { name: 'Query', value: kqlModelUsageByProject, isOptional: true }
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
                { name: 'PartId', value: 'total-tokens-project', isOptional: true }
                { name: 'PartTitle', value: '💰 Total Tokens by Project', isOptional: true }
                { name: 'PartSubTitle', value: 'All-time token usage by project', isOptional: true }
                { name: 'Query', value: kqlTotalTokensPerProject, isOptional: true }
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
