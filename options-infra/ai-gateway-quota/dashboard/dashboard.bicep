// Azure Portal Dashboard for APIM AI Gateway operations
// Uses ApiManagementGatewayLlmLog as primary source (reliable under load)
// Joined with ApiManagementGatewayLogs for caller identification via x-caller-name header

@description('Location for the dashboard')
param location string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

// ------------------
//    VARIABLES
// ------------------

var dashboardName = 'apim-quota-dashboard-${toLower(uniqueString(resourceGroup().id, location))}'

// Helper: join LLM logs with gateway logs to get caller identity
// ApiManagementGatewayLlmLog has: PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName
// ApiManagementGatewayLogs has: ResponseHeaders containing x-caller-name, x-caller-priority, x-caller-id
// (set by the outbound section of policy-per-model.xml; never present on BackendRequestHeaders)

var kqlTokenUsageOverTime = '''
let callerLogs = ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize CallerName = take_any(CallerName) by CorrelationId;
ApiManagementGatewayLlmLog
| where DeploymentName != ""
| summarize arg_max(TimeGenerated, PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName) by CorrelationId
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
| summarize arg_max(TimeGenerated, PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName) by CorrelationId
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
| summarize arg_max(TimeGenerated, PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName) by CorrelationId
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

var kqlSpilloverSummary = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| where isnotempty(CallerName)
| summarize
    SpilloverCount  = countif(IsFailover),
    TotalRequests   = count(),
    FirstSpillover  = minif(TimeGenerated, IsFailover),
    LastSpillover   = maxif(TimeGenerated, IsFailover)
    by CallerName
| where SpilloverCount > 0
| extend SpilloverRate = round(100.0 * SpilloverCount / TotalRequests, 1)
| project CallerName, SpilloverCount, TotalRequests, SpilloverRate, FirstSpillover, LastSpillover
| order by SpilloverCount desc
'''

var kqlSpilloverOverTime = '''
ApiManagementGatewayLogs
| where ResponseHeaders has "x-inference-failover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| where isnotempty(CallerName)
| summarize SpilloverCount = countif(IsFailover) by bin(TimeGenerated, 1h), CallerName
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
| where Url has_any ("/chat/completions", "/responses", "/embeddings", "/completions", "/images", "/audio", "/realtime", "/models")
| extend BackendPool   = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(BackendPool) and BackendPool != "unknown"
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
| where Url has_any ("/chat/completions", "/responses", "/embeddings", "/completions", "/images", "/audio", "/realtime", "/models")
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(BackendPool) and BackendPool != "unknown"
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
    'hidden-title': 'AI Gateway Operations Dashboard'
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
                  content: '# 🔒 AI Gateway Operations Dashboard\n\nMonitor range-based token usage, throttling, errors, routing, and failover activity.\n\nUse the Monthly Workbook for monthly quota and FinOps reporting.'
                  title: ''
                  subtitle: ''
                  markdownSource: 1
                }
              }
            }
          }
          // Token Usage Over Time - Row 2, chart
          {
            position: { x: 0, y: 2, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
          // Rate Limit Events (429s) - Row 7, left
          {
            position: { x: 0, y: 7, colSpan: 8, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
          // Error Breakdown - Row 7, right
          {
            position: { x: 8, y: 7, colSpan: 9, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
          // Model Usage by Caller - Row 11
          {
            position: { x: 0, y: 11, colSpan: 17, rowSpan: 4 }
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
          // Daily Usage by Caller - Row 15
          {
            position: { x: 0, y: 15, colSpan: 17, rowSpan: 4 }
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
          // Failover Events Summary - Row 19
          {
            position: { x: 0, y: 19, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
                { name: 'PartId', value: 'spillover-summary', isOptional: true }
                { name: 'PartTitle', value: '🔀 Inference Failover Events', isOptional: true }
                { name: 'PartSubTitle', value: 'Requests with a captured x-inference-failover trail', isOptional: true }
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
          // Failover Over Time - Row 23, chart
          {
            position: { x: 0, y: 23, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
                    yAxis: [ { name: 'SpilloverCount', type: 'long' } ]
                    splitBy: [ { name: 'CallerName', type: 'string' } ]
                    aggregation: 'Sum'
                  }
                  LegendOptions: { isEnabled: true, position: 'Bottom' }
                }
              }
            }
          }
          // Non-LLM Endpoint Usage (TTS, Whisper, embeddings, images) - Row 28
          {
            position: { x: 0, y: 28, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
          // Backend Distribution (grid) - Row 32
          {
            position: { x: 0, y: 32, colSpan: 17, rowSpan: 4 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
          // Backend Requests Over Time (chart) - Row 36
          {
            position: { x: 0, y: 36, colSpan: 17, rowSpan: 5 }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                { name: 'Scope', value: { resourceIds: [ logAnalyticsWorkspaceId ] }, isOptional: true }
                { name: 'Version', value: '2.0', isOptional: true }
                { name: 'TimeRange', value: 'P30D', isOptional: true }
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
              model: { format: 'utc', granularity: 'auto', relative: '30d' }
              displayCache: { name: 'UTC Time', value: 'Past 30 days' }
            }
          }
        }
      }
    }
  })
}

output dashboardId string = dashboard.id
