// Azure Portal Dashboard for APIM AI Gateway - Quota Tiers
// Uses ApiManagementGatewayLlmLog as primary source (reliable under load)
// Joined with ApiManagementGatewayLogs for caller identification via x-caller-name header

@description('Location for the dashboard')
param location string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Caller tier mapping JSON string (preserved for ai-gateway-quota main.bicep compatibility)')
param callerTierMapping string = '{}'

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-quota-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// Helper: join LLM logs with gateway logs to get caller identity
// ApiManagementGatewayLlmLog has: PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName
// ApiManagementGatewayLogs has: ResponseHeaders containing x-caller-name, x-caller-priority, x-caller-id
// (set by the outbound section of policy-per-model.xml; never present on BackendRequestHeaders)

var kqlQuotaOverview = '''
let callerLogs = ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize CallerName = take_any(CallerName), CallerPriority = take_any(CallerPriority) by CorrelationId;
ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| where TotalTokens > 0 or isnotempty(DeploymentName)
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
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
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
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize
    ThrottledRequests = count(),
    FirstThrottle = min(TimeGenerated),
    LastThrottle = max(TimeGenerated)
    by CallerName, CallerPriority
| order by ThrottledRequests desc
'''

var kqlModelUsageByCaller = '''
let callerLogs = ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
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
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize CallerName = take_any(CallerName), CallerPriority = take_any(CallerPriority) by CorrelationId;
ApiManagementGatewayLlmLog
| where TotalTokens > 0 or isnotempty(DeploymentName)
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
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize Count = count() by ResponseCode, CallerName, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
'''

var kqlMonthlyBudgetBurnDown = '''
let callerLogs = ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize CallerName = take_any(CallerName) by CorrelationId;
ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| where TotalTokens > 0 or isnotempty(DeploymentName)
| join kind=leftouter callerLogs on CorrelationId
| summarize CumulativeTokens = sum(TotalTokens) by CallerName, bin(TimeGenerated, 1h)
| order by CallerName, TimeGenerated asc
| serialize
| extend RunningTotal = row_cumsum(CumulativeTokens, CallerName != prev(CallerName))
'''

var kqlRemainingQuota = '''
ApiManagementGatewayLogs
| where TimeGenerated >= startofmonth(now())
| where ResponseHeaders has "x-quota-remaining-tokens"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend QuotaLimit = tolong(extract(@'"x-quota-limit-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend QuotaRemaining = tolong(extract(@'"x-quota-remaining-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| where isnotempty(CallerName)
| summarize arg_max(TimeGenerated, QuotaRemaining, QuotaLimit) by CallerName
| extend QuotaUsed = QuotaLimit - QuotaRemaining
| extend QuotaUsedPct = round(100.0 * QuotaUsed / QuotaLimit, 1)
| project CallerName, QuotaLimit, QuotaUsed, QuotaRemaining, QuotaUsedPct
| order by QuotaUsedPct desc
'''

var kqlSpilloverSummary = '''
ApiManagementGatewayLogs
| where TimeGenerated >= ago(7d)
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsSpillover = extract(@'"x-spillover":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(CallerName)
| summarize
    SpilloverCount  = countif(IsSpillover == "true"),
    TotalRequests   = count(),
    FirstSpillover  = minif(TimeGenerated, IsSpillover == "true"),
    LastSpillover   = maxif(TimeGenerated, IsSpillover == "true")
    by CallerName
| where SpilloverCount > 0
| extend SpilloverRate = round(100.0 * SpilloverCount / TotalRequests, 1)
| project CallerName, SpilloverCount, TotalRequests, SpilloverRate, FirstSpillover, LastSpillover
| order by SpilloverCount desc
'''

var kqlSpilloverOverTime = '''
ApiManagementGatewayLogs
| where TimeGenerated >= ago(7d)
| where ResponseHeaders has "x-spillover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsSpillover = extract(@'"x-spillover":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(CallerName)
| summarize SpilloverCount = countif(IsSpillover == "true") by bin(TimeGenerated, 1h), CallerName
| where SpilloverCount > 0
| order by TimeGenerated asc
'''

// Non-LLM endpoints (TTS, Whisper, embeddings, images). APIM's `largeLanguageModel`
// diagnostic only enriches DeploymentName/ModelName/Tokens for chat-completion-shaped
// JSON responses, so TTS (binary) and similar endpoints are invisible in
// ApiManagementGatewayLlmLog. We derive the deployment from the URL path of
// ApiManagementGatewayLogs instead.
var kqlNonLlmEndpoints = '''
ApiManagementGatewayLogs
| where Url matches regex @"/deployments/([^/]+)/(audio|images|embeddings)"
| extend DeploymentName = extract(@"/deployments/([^/]+)/", 1, Url)
| extend Endpoint = extract(@"/deployments/[^/]+/(audio/[^/?]+|images/[^/?]+|embeddings)", 1, Url)
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize
    Requests = count(),
    Errors = countif(ResponseCode >= 400),
    LastCall = max(TimeGenerated)
    by CallerName, CallerPriority, DeploymentName, Endpoint
| order by Requests desc
'''

// Backend distribution: how many requests each backend pool / individual backend
// handled, including failover and retry counts.
//
// Native APIM columns (preferred source of truth):
//   BackendId  → resource name of the *individual* backend resolved (multi-backend
//                pools naturally split across rows). Empty when the request never
//                reached the routing policy (401/403 rejected early).
//   BackendUrl → full resolved URL (host + path); used to derive a short label.
//
// Header (only used for the logical pool name — not available as a native column):
//   x-backend-pool → load-balancer pool that owns the resolved BackendId.
//
// Retry / failover context (still header-based; APIM has no native columns for these):
//   x-backend-retry-count, x-backend-attempt-trail, x-inference-failover.
var kqlBackendDistribution = '''
ApiManagementGatewayLogs
| extend BackendPool   = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend BackendPool   = iff(isempty(BackendPool), "(no-pool)", BackendPool)
| extend BackendShort  = iff(isempty(BackendId), "(none)", BackendId)
| extend RetryCount    = toint(extract(@'"x-backend-retry-count":"([^"]+)"',  1, tostring(ResponseHeaders)))
| extend AttemptTrail  = extract(@'"x-backend-attempt-trail":"([^"]+)"',      1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"',         1, tostring(ResponseHeaders))
| extend HadRetry      = isnotempty(AttemptTrail)  and AttemptTrail  != "none"
| extend HadFailover   = isnotempty(FailoverTrail) and FailoverTrail != "none"
| summarize
    Requests       = count(),
    Errors         = countif(ResponseCode >= 400),
    Throttled      = countif(ResponseCode == 429),
    RetryEvents    = countif(HadRetry),
    FailoverEvents = countif(HadFailover),
    AvgRetries     = round(avg(RetryCount), 2),
    MaxRetries     = max(RetryCount),
    LastCall       = max(TimeGenerated)
    by BackendPool, Backend = BackendShort
| extend ErrorRate = round(100.0 * Errors / Requests, 1)
| project BackendPool, Backend, Requests, Errors, ErrorRate, Throttled, RetryEvents, FailoverEvents, AvgRetries, MaxRetries, LastCall
| order by BackendPool asc, Requests desc
'''

// Backend Requests Over Time — stacked column chart of pool traffic over time.
var kqlBackendOverTime = '''
ApiManagementGatewayLogs
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(BackendPool)
| summarize Requests = count() by bin(TimeGenerated, 1h), BackendPool
| order by TimeGenerated asc
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
  properties: any({
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
                  content: '# 🔒 AI Gateway - Quota Tiers Dashboard\n\nMonitor per-caller token usage, quota consumption, and rate limit events.\nPriority Levels: **Production** (P1) · **Standard** (P2)\n\nData sourced from `ApiManagementGatewayLlmLog` joined with `ApiManagementGatewayLogs` for caller identification.'
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
          // Remaining Quota by Caller - Row 28, left
          {
            position: { x: 0, y: 28, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'remaining-quota', isOptional: true }
                { name: 'PartTitle', value: '💰 Remaining Monthly Quota by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Latest token budget remaining this month (% used)', isOptional: true }
                { name: 'Query', value: kqlRemainingQuota, isOptional: true }
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
          // Spillover Events Summary - Row 28, right
          {
            position: { x: 8, y: 28, colSpan: 9, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'spillover-summary', isOptional: true }
                { name: 'PartTitle', value: '🔀 PTU→PAYG Spillover Events (Last 7 Days)', isOptional: true }
                { name: 'PartSubTitle', value: 'Requests that spilled from PTU to PAYG due to capacity exhaustion', isOptional: true }
                { name: 'Query', value: kqlSpilloverSummary, isOptional: true }
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
          // Spillover Over Time - Row 32, chart
          {
            position: { x: 0, y: 32, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'spillover-over-time', isOptional: true }
                { name: 'PartTitle', value: '📉 PTU→PAYG Spillover Over Time', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly spillover event count by caller', isOptional: true }
                { name: 'Query', value: kqlSpilloverOverTime, isOptional: true }
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
                  Query: '${kqlSpilloverOverTime}\n'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'StackedColumn'
                  Dimensions: {
                    xAxis: { name: 'TimeGenerated', type: 'datetime' }
                    yAxis: [ { name: 'SpilloverCount', type: 'long' } ]
                    splitBy: [ { name: 'CallerName', type: 'string' } ]
                    aggregation: 'Sum'
                  }
                  LegendOptions: { isEnabled: true, position: 'Bottom' }
                }
              }
            }
          }
          // Non-LLM Endpoint Usage (TTS, Whisper, embeddings, images) - Row 37
          {
            position: { x: 0, y: 37, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'non-llm-endpoints', isOptional: true }
                { name: 'PartTitle', value: '🎙️ Non-LLM Endpoint Usage (TTS / Whisper / Embeddings)', isOptional: true }
                { name: 'PartSubTitle', value: 'Derived from URL path — APIM\'s LLM log only enriches chat-completion responses', isOptional: true }
                { name: 'Query', value: kqlNonLlmEndpoints, isOptional: true }
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
          // Backend Distribution (grid) - Row 41
          {
            position: { x: 0, y: 41, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'backend-distribution', isOptional: true }
                { name: 'PartTitle', value: '⚙️ Backend Distribution', isOptional: true }
                { name: 'PartSubTitle', value: 'Requests per backend pool & individual backend, with retry / failover counts', isOptional: true }
                { name: 'Query', value: kqlBackendDistribution, isOptional: true }
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
          // Backend Requests Over Time (chart) - Row 45
          {
            position: { x: 0, y: 45, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'backend-over-time', isOptional: true }
                { name: 'PartTitle', value: '📊 Backend Requests Over Time', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly request count per backend pool', isOptional: true }
                { name: 'Query', value: kqlBackendOverTime, isOptional: true }
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
                  Query: '${kqlBackendOverTime}\n'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'StackedColumn'
                  Dimensions: {
                    xAxis: { name: 'TimeGenerated', type: 'datetime' }
                    yAxis: [ { name: 'Requests', type: 'long' } ]
                    splitBy: [ { name: 'BackendPool', type: 'string' } ]
                    aggregation: 'Sum'
                  }
                  LegendOptions: { isEnabled: true, position: 'Bottom' }
                }
              }
            }
          }
          // Caller Tier Config Reference (local ai-gateway-quota tile)
          {
            position: { x: 0, y: 50, colSpan: 17, rowSpan: 2 }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  content: '## ⚙️ Caller Priority Configuration\n\nCurrent mapping (from APIM contract map):\n```json\n${callerTierMapping}\n```'
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
  })
}

output dashboardId string = dashboard.id
