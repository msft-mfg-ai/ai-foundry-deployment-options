// Azure Portal Dashboard for shared APIM AI Gateway monitoring
// Uses ApiManagementGatewayLlmLog joined with ApiManagementGatewayLogs response headers.

@description('Location for the dashboard')
param location string

@description('Dashboard display name')
param dashboardDisplayName string

@description('Application Insights resource ID for compatibility with existing callers')
param applicationInsightsId string

@description('Application Insights name for dashboard subtitles')
param applicationInsightsName string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-token-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// Helper: join LLM logs with gateway logs to get caller identity
// ApiManagementGatewayLlmLog has: PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName
// ApiManagementGatewayLogs has: ResponseHeaders containing x-caller-name, x-caller-priority, x-caller-id
// Headers are captured from ResponseHeaders by modules/apim/log-settings.bicep.

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
| where ResponseHeaders has_any ("x-quota-remaining-tokens", "x-quota-tokens-consumed")
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend QuotaRemaining = tolong(extract(@'"x-quota-remaining-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend QuotaTokensConsumed = tolong(extract(@'"x-quota-tokens-consumed":"([^"]+)"', 1, tostring(ResponseHeaders)))
| where isnotempty(CallerName)
| summarize arg_max(TimeGenerated, QuotaRemaining), MonthQuotaTokensConsumed = sum(QuotaTokensConsumed), Requests = count() by CallerName
| project CallerName, MonthQuotaTokensConsumed, LatestQuotaRemaining = QuotaRemaining, Requests
| order by MonthQuotaTokensConsumed desc
'''

var kqlSpilloverSummary = '''
ApiManagementGatewayLogs
| where TimeGenerated >= ago(7d)
| where ResponseHeaders has "x-inference-failover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend HadFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| summarize
    FailoverCount = countif(HadFailover),
    TotalRequests = count(),
    FirstFailover = minif(TimeGenerated, HadFailover),
    LastFailover = maxif(TimeGenerated, HadFailover)
    by CallerName
| where FailoverCount > 0
| extend FailoverRate = round(100.0 * FailoverCount / TotalRequests, 1)
| project CallerName, FailoverCount, TotalRequests, FailoverRate, FirstFailover, LastFailover
| order by FailoverCount desc
'''

var kqlSpilloverOverTime = '''
ApiManagementGatewayLogs
| where TimeGenerated >= ago(7d)
| where ResponseHeaders has "x-inference-failover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend HadFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| summarize FailoverCount = countif(HadFailover) by bin(TimeGenerated, 1h), CallerName
| where FailoverCount > 0
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

var kqlPriorityDistribution = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-priority"
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize Requests = count(), Callers = dcount(CallerName), Errors = countif(ResponseCode >= 400) by CallerPriority
| extend ErrorRate = round(100.0 * Errors / Requests, 1)
| order by Requests desc
'''

var kqlRetryDistribution = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-backend-retry-count"
| extend RetryCount = toint(extract(@'"x-backend-retry-count":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize Requests = count(), Callers = dcount(CallerName), Errors = countif(ResponseCode >= 400) by RetryCount, BackendPool
| order by RetryCount asc, Requests desc
'''

var kqlFailoverTrail = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-inference-failover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend AttemptTrail = extract(@'"x-backend-attempt-trail":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend RetryCount = toint(extract(@'"x-backend-retry-count":"([^"]+)"', 1, tostring(ResponseHeaders)))
| where isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| project TimeGenerated, CorrelationId, CallerName, BackendPool, RetryCount, AttemptTrail, FailoverTrail, ResponseCode, BackendId
| order by TimeGenerated desc
| limit 100
'''

var kqlAttemptedBackends = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-backend-attempt-trail"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend RequestedModel = extract(@'"x-requested-model":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend AttemptTrail = extract(@'"x-backend-attempt-trail":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend AttemptedBackends = iff(isempty(AttemptTrail) or AttemptTrail == "none", 0, array_length(split(AttemptTrail, ",")))
| summarize Requests = count(), AvgAttemptedBackends = round(avg(AttemptedBackends), 2), MaxAttemptedBackends = max(AttemptedBackends), RetriedRequests = countif(AttemptedBackends > 1) by CallerName, RequestedModel, BackendPool
| order by RetriedRequests desc, Requests desc
'''

var kqlPtuPaygSplit = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-backend-pool"
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend BackendTier = case(BackendPool has "ptu", "PTU", BackendPool has "payg", "PAYG", "Other")
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend TokensConsumed = tolong(extract(@'"x-tokens-consumed":"([^"]+)"', 1, tostring(ResponseHeaders)))
| summarize Requests = count(), Tokens = sum(TokensConsumed), Callers = dcount(CallerName), Errors = countif(ResponseCode >= 400) by BackendTier, BackendPool
| order by Requests desc
'''

var kqlFoundryAgentActivity = '''
ApiManagementGatewayLogs
| where ResponseHeaders has_any ("x-foundry-agent-id", "x-foundry-project-name", "x-foundry-project-id")
| extend AgentId = extract(@'"x-foundry-agent-id":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend ProjectName = extract(@'"x-foundry-project-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend ProjectId = extract(@'"x-foundry-project-id":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend TokensConsumed = tolong(extract(@'"x-tokens-consumed":"([^"]+)"', 1, tostring(ResponseHeaders)))
| where isnotempty(AgentId) or isnotempty(ProjectName) or isnotempty(ProjectId)
| summarize Requests = count(), Tokens = sum(TokensConsumed), Errors = countif(ResponseCode >= 400), LastCall = max(TimeGenerated) by AgentId, ProjectName, ProjectId, CallerName
| order by Requests desc
'''

var kqlQuotaConsumption = '''
ApiManagementGatewayLogs
| where ResponseHeaders has_any ("x-quota-tokens-consumed", "x-quota-remaining-tokens", "x-ratelimit-remaining-tokens")
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend QuotaTokensConsumed = tolong(extract(@'"x-quota-tokens-consumed":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend QuotaRemaining = tolong(extract(@'"x-quota-remaining-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend RateLimitRemaining = tolong(extract(@'"x-ratelimit-remaining-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| summarize arg_max(TimeGenerated, QuotaRemaining), QuotaTokensConsumed = sum(QuotaTokensConsumed), MinRateLimitRemaining = min(RateLimitRemaining), Requests = count() by CallerName
| project CallerName, QuotaTokensConsumed, LatestQuotaRemaining = QuotaRemaining, MinRateLimitRemaining, Requests
| order by QuotaTokensConsumed desc
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
    'hidden-title': dashboardDisplayName
    'application-insights-name': applicationInsightsName
    'application-insights-id': applicationInsightsId
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
                  content: '# 🤖 APIM AI Gateway Dashboard\n\nMonitor per-caller token usage, quota consumption, and rate limit events.\nPriority Levels: **Production** (P1) · **Standard** (P2)\n\nData sourced from `ApiManagementGatewayLlmLog` joined with captured APIM `ResponseHeaders` in `ApiManagementGatewayLogs`.'
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
                { name: 'PartTitle', value: '💰 Monthly Quota by Caller', isOptional: true }
                { name: 'PartSubTitle', value: 'Consumed and latest remaining quota token headers', isOptional: true }
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
                { name: 'PartTitle', value: '🔀 Inference Failover Events (Last 7 Days)', isOptional: true }
                { name: 'PartSubTitle', value: 'Requests with x-inference-failover trail captured', isOptional: true }
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
                { name: 'PartTitle', value: '📉 Inference Failover Over Time', isOptional: true }
                { name: 'PartSubTitle', value: 'Hourly failover event count by caller', isOptional: true }
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
                    yAxis: [ { name: 'FailoverCount', type: 'long' } ]
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
          // Priority Distribution
          {
            position: { x: 0, y: 50, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'priority-distribution', isOptional: true }
                { name: 'PartTitle', value: '🏷️ Priority Distribution', isOptional: true }
                { name: 'PartSubTitle', value: 'Request volume by x-caller-priority', isOptional: true }
                { name: 'Query', value: kqlPriorityDistribution, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // Retry Count Distribution
          {
            position: { x: 8, y: 50, colSpan: 9, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'retry-distribution', isOptional: true }
                { name: 'PartTitle', value: '🔁 Retry Count Distribution', isOptional: true }
                { name: 'PartSubTitle', value: 'Requests by x-backend-retry-count and pool', isOptional: true }
                { name: 'Query', value: kqlRetryDistribution, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // Failover Trail
          {
            position: { x: 0, y: 54, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'failover-trail', isOptional: true }
                { name: 'PartTitle', value: '🧭 Failover Trail', isOptional: true }
                { name: 'PartSubTitle', value: 'Recent x-inference-failover and x-backend-attempt-trail values', isOptional: true }
                { name: 'Query', value: kqlFailoverTrail, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // Attempted Backends Per Request
          {
            position: { x: 0, y: 58, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'attempted-backends', isOptional: true }
                { name: 'PartTitle', value: '🎯 Attempted Backends per Request', isOptional: true }
                { name: 'PartSubTitle', value: 'Derived from x-backend-attempt-trail', isOptional: true }
                { name: 'Query', value: kqlAttemptedBackends, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // PTU vs PAYG Split
          {
            position: { x: 8, y: 58, colSpan: 9, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'ptu-payg-split', isOptional: true }
                { name: 'PartTitle', value: '⚖️ PTU vs PAYG Split', isOptional: true }
                { name: 'PartSubTitle', value: 'Traffic classified by x-backend-pool', isOptional: true }
                { name: 'Query', value: kqlPtuPaygSplit, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // Foundry Agent Activity
          {
            position: { x: 0, y: 62, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P7D', isOptional: true }
                { name: 'PartId', value: 'foundry-agent-activity', isOptional: true }
                { name: 'PartTitle', value: '🤖 Foundry Agent Activity', isOptional: true }
                { name: 'PartSubTitle', value: 'x-foundry-agent-id, project name, and project id', isOptional: true }
                { name: 'Query', value: kqlFoundryAgentActivity, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
              ]
              settings: {}
            }
          }
          // Quota Consumption
          {
            position: { x: 0, y: 66, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'quota-consumption', isOptional: true }
                { name: 'PartTitle', value: '🧮 Quota Consumption', isOptional: true }
                { name: 'PartSubTitle', value: 'x-quota-tokens-consumed and remaining token headers', isOptional: true }
                { name: 'Query', value: kqlQuotaConsumption, isOptional: true }
                { name: 'ControlType', value: 'AnalyticsGrid', isOptional: true }
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
