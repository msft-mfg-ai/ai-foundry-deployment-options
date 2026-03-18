// Azure Portal Dashboard for APIM AI Gateway - Quota Tiers
// Uses ApiManagementGatewayLlmLog as primary source (reliable under load)
// Joined with ApiManagementGatewayLogs for caller identification via x-caller-name header

@description('Location for the dashboard')
param location string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Caller tier mapping JSON string (for reference in quota panel)')
param callerTierMapping string = '{}'

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-quota-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// Helper: join LLM logs with gateway logs to get caller identity
// ApiManagementGatewayLlmLog has: PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName
// ApiManagementGatewayLogs has: BackendRequestHeaders containing x-caller-name, x-caller-priority, x-caller-id

var kqlQuotaOverview = '''
let callerLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-priority"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| summarize CallerName = take_any(CallerName), CallerPriority = take_any(CallerPriority) by CorrelationId;
ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| join kind=leftouter callerLogs on CorrelationId
| summarize
    MonthlyTokens = sum(TotalTokens),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    Requests = dcount(CorrelationId)
    by CallerName, CallerPriority
| project CallerName, CallerPriority, MonthlyTokens, PromptTokens, CompletionTokens, Requests
| order by MonthlyTokens desc
'''

var kqlTokenUsageOverTime = '''
let callerLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| summarize CallerName = take_any(CallerName) by CorrelationId;
ApiManagementGatewayLlmLog
| where DeploymentName != ""
| join kind=leftouter callerLogs on CorrelationId
| summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1h), CallerName
| order by TimeGenerated asc
'''

var kqlRateLimitEvents = '''
ApiManagementGatewayLogs
| where ResponseCode == 429
| extend CallerName = coalesce(
    extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders)),
    extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
  )
| extend CallerPriority = coalesce(
    extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(BackendRequestHeaders)),
    extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
  )
| summarize
    ThrottledRequests = count(),
    FirstThrottle = min(TimeGenerated),
    LastThrottle = max(TimeGenerated)
    by CallerName, CallerPriority
| order by ThrottledRequests desc
'''

var kqlModelUsageByCaller = '''
let callerLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| summarize CallerName = take_any(CallerName) by CorrelationId;
ApiManagementGatewayLlmLog
| where DeploymentName != ""
| join kind=leftouter callerLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = dcount(CorrelationId)
by CallerName, DeploymentName, ModelName
| order by CallerName asc, TotalTokens desc
'''

var kqlDailyUsageByCaller = '''
let callerLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| summarize CallerName = take_any(CallerName), CallerPriority = take_any(CallerPriority) by CorrelationId;
ApiManagementGatewayLlmLog
| join kind=leftouter callerLogs on CorrelationId
| summarize
    TotalTokens = sum(TotalTokens),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    Requests = dcount(CorrelationId)
by bin(TimeGenerated, 1d), CallerName, CallerPriority
| order by TimeGenerated desc, TotalTokens desc
'''

var kqlErrorBreakdown = '''
ApiManagementGatewayLogs
| where ResponseCode >= 400
| extend CallerName = coalesce(
    extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders)),
    extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
  )
| summarize Count = count() by ResponseCode, CallerName, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
'''

var kqlMonthlyBudgetBurnDown = '''
let callerLogs = ApiManagementGatewayLogs
| where BackendRequestHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
| summarize CallerName = take_any(CallerName) by CorrelationId;
ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| join kind=leftouter callerLogs on CorrelationId
| summarize CumulativeTokens = sum(TotalTokens) by CallerName, bin(TimeGenerated, 1h)
| order by CallerName, TimeGenerated asc
| serialize
| extend RunningTotal = row_cumsum(CumulativeTokens, CallerName != prev(CallerName))
'''

// Helper function to create a LogsDashboardPart tile
// (Bicep doesn't support functions, so we use a helper variable for the common input structure)

// ------------------
//    RESOURCES
// ------------------

resource dashboard 'Microsoft.Portal/dashboards@2022-12-01-preview' = {
  name: dashboardName
  location: location
  tags: {
    'hidden-title': 'AI Gateway - Quota Tiers Dashboard'
  }
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          // Title
          {
            position: { x: 0, y: 0, colSpan: 17, rowSpan: 2 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  content: '# 🔒 AI Gateway - Quota Tiers Dashboard\n\nMonitor per-caller token usage, quota consumption, and rate limit events.\nPriority Levels: **Production** (P1) · **Standard** (P2) · **Economy** (P3)\n\nData sourced from `ApiManagementGatewayLlmLog` joined with `ApiManagementGatewayLogs` for caller identification.'
                  title: ''
                  subtitle: ''
                  markdownSource: 1
                }
              }
            }
          }
          // Quota Overview - Row 2, full width
          {
            position: { x: 0, y: 2, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'quota-overview', isOptional: true }
                { name: 'PartTitle', value: '📊 Caller Quota Overview (This Month)', isOptional: true }
                { name: 'PartSubTitle', value: 'Monthly token usage per caller with priority level', isOptional: true }
                { name: 'Query', value: kqlQuotaOverview, isOptional: true }
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
          // Token Usage Over Time - Row 6, chart
          {
            position: { x: 0, y: 6, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'usage-over-time', isOptional: true }
                { name: 'PartTitle', value: '📈 Token Usage Over Time by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly token consumption', isOptional: true }
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
          // Rate Limit Events (429s) - Row 11, left
          {
            position: { x: 0, y: 11, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'rate-limits', isOptional: true }
                { name: 'PartTitle', value: '🚫 Rate Limit Events (429)', isOptional: true }
                { name: 'PartSubTitle', value: 'Throttled requests by caller', isOptional: true }
                { name: 'Query', value: kqlRateLimitEvents, isOptional: true }
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
          // Error Breakdown - Row 11, right
          {
            position: { x: 8, y: 11, colSpan: 9, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'error-breakdown', isOptional: true }
                { name: 'PartTitle', value: '⚠️ Error Breakdown', isOptional: true }
                { name: 'PartSubTitle', value: 'HTTP errors (4xx/5xx) by caller and status code', isOptional: true }
                { name: 'Query', value: kqlErrorBreakdown, isOptional: true }
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
          // Model Usage by Caller - Row 15
          {
            position: { x: 0, y: 15, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'model-by-caller', isOptional: true }
                { name: 'PartTitle', value: '🧠 Model Usage by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Token consumption per deployment/model by caller', isOptional: true }
                { name: 'Query', value: kqlModelUsageByCaller, isOptional: true }
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
          // Daily Usage by Caller - Row 19
          {
            position: { x: 0, y: 19, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'daily-usage', isOptional: true }
                { name: 'PartTitle', value: '📊 Daily Usage by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Daily token breakdown with priority info', isOptional: true }
                { name: 'Query', value: kqlDailyUsageByCaller, isOptional: true }
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
          // Monthly Budget Burn-Down - Row 23, chart
          {
            position: { x: 0, y: 23, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'budget-burndown', isOptional: true }
                { name: 'PartTitle', value: '🔥 Monthly Token Burn-Down by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Cumulative token usage this month', isOptional: true }
                { name: 'Query', value: kqlMonthlyBudgetBurnDown, isOptional: true }
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
                  Query: '${kqlMonthlyBudgetBurnDown}\n'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'Line'
                  Dimensions: {
                    xAxis: { name: 'TimeGenerated', type: 'datetime' }
                    yAxis: [ { name: 'RunningTotal', type: 'long' } ]
                    splitBy: [ { name: 'CallerName', type: 'string' } ]
                    aggregation: 'Sum'
                  }
                  LegendOptions: { isEnabled: true, position: 'Bottom' }
                }
              }
            }
          }
          // Caller Tier Config Reference
          {
            position: { x: 0, y: 28, colSpan: 17, rowSpan: 2 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  content: '## ⚙️ Caller Priority Configuration\n\nCurrent mapping (from APIM Named Value `caller-tier-mapping`):\n```json\n${callerTierMapping}\n```'
                  title: ''
                  subtitle: ''
                  markdownSource: 1
                }
              }
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
        filterLocale: { value: 'en-us' }
        filters: {
          value: {
            MsPortalFx_TimeRange: {
              model: { format: 'utc', granularity: 'auto', relative: '7d' }
              displayCache: { name: 'UTC Time', value: 'Past 7 days' }
            }
          }
        }
      }
    }
  }
}

output dashboardId string = dashboard.id
