// ============================================================================
// Azure Monitor Workbook — AI Gateway Monthly Report
// ============================================================================
// Interactive month-selectable report that mirrors every tile from the portal
// dashboard, plus adds Foundry-level token & estimated-cost analytics that
// aren't available on the fixed-layout dashboard.
//
// Sections:
//   1. Caller Quota      (Quota Overview, Remaining Quota, Burn-Down, Daily)
//   2. Models            (Model Usage by Caller, Token Usage Over Time, non-LLM)
//   3. Foundries         (per-Foundry tokens, per-Foundry over time, per-model
//                         est. cost, cost by Foundry)
//   4. Backends          (Backend Distribution, Backend Requests Over Time)
//   5. Reliability       (429s, Errors, Spillover Summary, Spillover Over Time)
//   6. Billed Cost       (real Cost Management data via AICostData_CL —
//                         Total MTD, by Foundry, by Project tag, by Meter,
//                         Daily trend. Requires DEPLOY_COST_INGESTION=true.)
//   7. Hybrid Cost       (near-real-time cost from LLM log tokens ×
//                         Cost-Mgmt-derived per-Foundry blended rate.
//                         Includes reconciliation vs Sections 3 & 6.)
//
// Deployed as `Microsoft.Insights/workbooks` — accessed via Azure Monitor >
// Workbooks. Pin individual tiles to a portal dashboard as needed.
//
// COST SOURCE NOTE
// All cost figures are sourced from `AICostData_CL` (Azure Cost Management
// data ingested daily by the Cost Ingestion Logic App). No hand-curated rate
// table — Section 3 shows the actual billed cost per (Foundry, ModelFamily)
// derived from the Cost Mgmt meter names, and per-caller cost is allocated
// proportionally by each caller's share of the Foundry's LLM tokens.
// Requires DEPLOY_COST_INGESTION=true and at least one successful
// Logic App run (or a `scripts/backfill-cost-ingestion.sh` run).
// ============================================================================

@description('Location for the workbook')
param location string

@description('Log Analytics Workspace resource ID (KQL data source)')
param logAnalyticsWorkspaceId string

// ---------------------------------------------------------------------------
// Deterministic name so subsequent deploys update in place.
// ---------------------------------------------------------------------------
var workbookGuid = guid(resourceGroup().id, 'ai-gateway-monthly-report-v2-workbook')

// ---------------------------------------------------------------------------
// KQL query fragments (kept in variables so the workbookContent object stays
// readable). Each references `{SelectedMonth}` — the workbook runtime
// substitutes the dropdown value before running the query.
// ---------------------------------------------------------------------------

// Helper subquery used across many tiles: caller identity dedupe per request.
// Filter out ApiManagementGatewayLogs rows that don't carry the caller-priority
// header so `take_any(CallerPriority)` can't pick an empty string — otherwise
// the same CallerName appears twice in Quota Overview (once with priority
// "standard", once with "").
var callerLogsFrag = '''let callerLogs = ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(CallerName) and CallerName != "unknown"
| summarize
    CallerName = take_any(CallerName),
    CallerPriority = take_anyif(CallerPriority, isnotempty(CallerPriority))
    by CorrelationId
| extend CallerPriority = coalesce(CallerPriority, "standard");'''

// Helper: dedupe ApiManagementGatewayLlmLog to ONE row per CorrelationId.
// The APIM LLM logger emits multiple rows per request during streaming (one
// per token-usage snapshot). Naive sum(TotalTokens) can therefore over-count
// rows/CorrelationId. Naive sum(TotalTokens) therefore over-counts every
// token metric by ~2x. arg_max on TimeGenerated keeps the FINAL snapshot,
// which carries the cumulative totals for the whole request.
var llmLogFrag = '''let llmLogDedup = ApiManagementGatewayLlmLog
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| summarize arg_max(TimeGenerated, PromptTokens, CompletionTokens, TotalTokens, DeploymentName, ModelName) by CorrelationId;'''

// The collector intentionally re-queries a rolling four-day window. Keep only
// the newest copy of each stable billing row before aggregating cost.
var costDataFrag = '''let costData = AICostData_CL
| where BillingDate >= monthStart and BillingDate < monthEnd
| summarize arg_max(TimeGenerated, *) by
    BillingDate,
    SubscriptionId,
    ResourceGroup,
    FoundryResource,
    Project,
    ServiceName,
    Meter,
    Currency;'''

// Caller Quota Overview (grid)
var qQuotaOverview = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0 or isnotempty(DeploymentName)
| join kind=inner callerLogs on CorrelationId
| summarize
    MonthlyTokens = sum(TotalTokens),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    Requests = dcount(CorrelationId)
    by CallerName, CallerPriority
| order by MonthlyTokens desc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Remaining Quota (grid with heat map on %-used)
var qRemainingQuota = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
let quotaLimits = ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseHeaders has "x-quota-limit-tokens"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend QuotaLimit = tolong(extract(@'"x-quota-limit-tokens":"([^"]+)"', 1, tostring(ResponseHeaders)))
| where isnotempty(CallerName) and CallerName != "unknown" and QuotaLimit > 0
| summarize QuotaLimit = max(QuotaLimit) by CallerName;
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0
| join kind=inner callerLogs on CorrelationId
| summarize QuotaUsed = sum(TotalTokens) by CallerName
| join kind=inner quotaLimits on CallerName
| extend QuotaRemaining = QuotaLimit - QuotaUsed
| extend QuotaUsedPct = iff(QuotaLimit > 0, round(100.0 * QuotaUsed / QuotaLimit, 1), real(null))
| project CallerName, QuotaLimit, QuotaUsed, QuotaRemaining, QuotaUsedPct
| order by QuotaUsedPct desc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Token Burn-Down (line chart, daily). Emits per-caller daily totals; the
// workbook's chart visualization applies "Total: Running" so we don't need
// row_cumsum() here. (Doing cumsum in KQL alongside the chart's Sum aggregate
// double-cumulated and produced the 553M inflation.)
var qBurnDown = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0
| join kind=inner callerLogs on CorrelationId
| summarize DailyTokens = sum(TotalTokens) by CallerName, bin(TimeGenerated, 1d)
| order by TimeGenerated asc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Daily Usage by Caller (grid)
var qDailyUsage = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0 or isnotempty(DeploymentName)
| join kind=inner callerLogs on CorrelationId
| summarize
    TotalTokens = sum(TotalTokens),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    Requests = dcount(CorrelationId)
    by bin(TimeGenerated, 1d), CallerName, CallerPriority
| order by TimeGenerated desc, TotalTokens desc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Model Usage by Caller (grid)
var qModelUsage = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where DeploymentName != ""
| join kind=inner callerLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = dcount(CorrelationId)
    by CallerName, DeploymentName, ModelName
| order by CallerName asc, TotalTokens desc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Token Usage Over Time (stacked column - hourly)
var qTokenUsageOverTime = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__CALLER_LOGS__
__LLM_LOG__
llmLogDedup
| where DeploymentName != ""
| join kind=inner callerLogs on CorrelationId
| summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1h), CallerName
| order by TimeGenerated asc''', '__CALLER_LOGS__', callerLogsFrag), '__LLM_LOG__', llmLogFrag)

// Non-LLM Endpoints (grid) — TTS / Whisper / embeddings / images
var qNonLlmEndpoints = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
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
| order by Requests desc'''

// ---- FOUNDRY-LEVEL TILES ---------------------------------------------------
// Every APIM backend URL takes the form `https://<foundry>.cognitiveservices.azure.com/...`
// or `https://<foundry>.openai.azure.com/...`. We extract the hostname's first
// label as FoundryAccount, which uniquely identifies each backing Foundry.

// Helper: join LlmLog with GatewayLogs on CorrelationId to get BackendUrl,
// then derive FoundryAccount. Emitted as a subquery block for reuse.
var foundryJoinFrag = '''let backendMap = ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where isnotempty(BackendUrl)
| extend FoundryAccount = tostring(split(replace_string(replace_string(BackendUrl, "https://", ""), "http://", ""), ".")[0])
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(FoundryAccount) and FoundryAccount != ""
| summarize FoundryAccount = take_any(FoundryAccount),
            BackendPool    = take_any(BackendPool),
            CallerName     = take_any(CallerName)
            by CorrelationId;'''

// Foundry Token Consumption (grid)
var qFoundryTokens = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__FOUNDRY_JOIN__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0 or isnotempty(DeploymentName)
| join kind=inner backendMap on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = dcount(CorrelationId),
    UniqueCallers = dcount(CallerName),
    UniqueModels = dcount(DeploymentName)
    by FoundryAccount, BackendPool
| order by TotalTokens desc''', '__FOUNDRY_JOIN__', foundryJoinFrag), '__LLM_LOG__', llmLogFrag)

// Foundry Token Consumption Over Time (stacked column, daily)
var qFoundryTokensOverTime = replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__FOUNDRY_JOIN__
__LLM_LOG__
llmLogDedup
| where TotalTokens > 0
| join kind=inner backendMap on CorrelationId
| summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1d), FoundryAccount
| order by TimeGenerated asc''', '__FOUNDRY_JOIN__', foundryJoinFrag), '__LLM_LOG__', llmLogFrag)

// Cost by Foundry & Model (grid) — real billed cost from AICostData_CL,
// joined with token counts from LlmLog for context. Meter names are mapped
// to model family via case() on well-known substrings; anything unmapped
// falls through as the raw meter name. Non-LLM meters (speech, whisper) are
// preserved so the totals reconcile to Section 6.
var qFoundryCost = replace(replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
__FOUNDRY_JOIN__
__LLM_LOG__
let billed = costData
    | extend MeterLower = tolower(Meter)
    | extend ModelFamily = case(
        MeterLower has "5.4 nano" or MeterLower has "5.4-nano", "gpt-5.4-nano",
        MeterLower has "5.4 mini" or MeterLower has "5.4-mini", "gpt-5.4-mini",
        MeterLower has "5.4", "gpt-5.4",
        MeterLower has "4.1 nano" or MeterLower has "4.1-nano", "gpt-4.1-nano",
        MeterLower has "4.1 mini" or MeterLower has "4.1-mini", "gpt-4.1-mini",
        MeterLower has "4.1", "gpt-4.1",
        MeterLower has "embedding-3-large", "text-embedding-3-large",
        MeterLower has "embedding-3-small", "text-embedding-3-small",
        MeterLower has "whisper", "whisper",
        MeterLower has "speech", "speech",
        Meter)
    | summarize BilledUsd = round(sum(BilledCost), 4) by FoundryAccount = tolower(FoundryResource), ModelFamily;
let tokens = llmLogDedup
    | where isnotempty(DeploymentName)
    | join kind=inner backendMap on CorrelationId
    | extend ModelKey = tolower(coalesce(iff(ModelName != "", ModelName, ""), DeploymentName))
    | extend ModelFamily = case(
        ModelKey startswith "gpt-4.1-nano",           "gpt-4.1-nano",
        ModelKey startswith "gpt-4.1-mini",           "gpt-4.1-mini",
        ModelKey startswith "gpt-4.1",                "gpt-4.1",
        ModelKey startswith "gpt-5.4-nano",           "gpt-5.4-nano",
        ModelKey startswith "gpt-5.4-mini",           "gpt-5.4-mini",
        ModelKey startswith "gpt-5.4",                "gpt-5.4",
        ModelKey startswith "text-embedding-3-large", "text-embedding-3-large",
        ModelKey startswith "text-embedding-3-small", "text-embedding-3-small",
        ModelKey)
    | summarize
        TotalTokens = sum(TotalTokens),
        Requests = dcount(CorrelationId)
        by FoundryAccount = tolower(FoundryAccount), ModelFamily;
billed
| join kind=fullouter tokens on FoundryAccount, ModelFamily
| project FoundryAccount = coalesce(FoundryAccount, FoundryAccount1),
          ModelFamily    = coalesce(ModelFamily, ModelFamily1),
          TotalTokens    = coalesce(TotalTokens, tolong(0)),
          Requests       = coalesce(Requests, tolong(0)),
          BilledUsd      = coalesce(BilledUsd, 0.0)
| order by BilledUsd desc''', '__FOUNDRY_JOIN__', foundryJoinFrag), '__LLM_LOG__', llmLogFrag), '__COST_DATA__', costDataFrag)

// Cost per Caller (grid) — allocates each Foundry's billed cost
// proportionally by the caller's share of the Foundry's LLM tokens.
// Callers that never sent LLM traffic (speech-only) won't appear.
var qCallerCost = replace(replace(replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
__CALLER_LOGS__
__FOUNDRY_JOIN__
__LLM_LOG__
let foundryBilled = costData
    | summarize BilledUsd = sum(BilledCost) by FoundryKey = tolower(FoundryResource);
let callerTokensPerFoundry = llmLogDedup
    | join kind=inner callerLogs on CorrelationId
    | join kind=inner backendMap on CorrelationId
    | extend FoundryKey = tolower(FoundryAccount)
    | summarize
        Tokens = sum(TotalTokens),
        Requests = dcount(CorrelationId)
        by CallerName, CallerPriority, FoundryKey;
let foundryTokenTotals = callerTokensPerFoundry
    | summarize FoundryTokens = sum(Tokens) by FoundryKey;
callerTokensPerFoundry
| join kind=leftouter foundryBilled on FoundryKey
| join kind=leftouter foundryTokenTotals on FoundryKey
| extend Share = iff(FoundryTokens > 0, todouble(Tokens) / todouble(FoundryTokens), 0.0)
| extend AllocatedUsd = coalesce(BilledUsd, 0.0) * Share
| summarize
    TotalTokens = sum(Tokens),
    Requests = sum(Requests),
    AllocatedUsd = round(sum(AllocatedUsd), 4)
    by CallerName, CallerPriority
| order by AllocatedUsd desc''', '__CALLER_LOGS__', callerLogsFrag), '__FOUNDRY_JOIN__', foundryJoinFrag), '__LLM_LOG__', llmLogFrag), '__COST_DATA__', costDataFrag)

// ---- BACKEND-LEVEL TILES ---------------------------------------------------
var qBackendDistribution = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where Url has_any ("/chat/completions", "/responses", "/embeddings", "/completions", "/images", "/audio", "/realtime", "/models")
| extend BackendPool   = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(BackendPool) and BackendPool != "unknown"
| extend BackendShort  = iff(isempty(BackendId), "(none)", BackendId)
| extend RetryCount    = toint(extract(@'"x-backend-retry-count":"([^"]+)"', 1, tostring(ResponseHeaders)))
| extend AttemptTrail  = extract(@'"x-backend-attempt-trail":"([^"]+)"',    1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"',       1, tostring(ResponseHeaders))
| extend HadRetry      = isnotempty(AttemptTrail) and AttemptTrail != "none"
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
| order by BackendPool asc, Requests desc'''

var qBackendOverTime = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where Url has_any ("/chat/completions", "/responses", "/embeddings", "/completions", "/images", "/audio", "/realtime", "/models")
| extend BackendPool = extract(@'"x-backend-pool":"([^"]+)"', 1, tostring(ResponseHeaders))
| where isnotempty(BackendPool) and BackendPool != "unknown"
| summarize Requests = count() by bin(TimeGenerated, 1h), BackendPool
| order by TimeGenerated asc'''

// ---- RELIABILITY TILES -----------------------------------------------------
var qRateLimits = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseCode == 429
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend CallerPriority = extract(@'"x-caller-priority":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize
    ThrottledRequests = count(),
    FirstThrottle = min(TimeGenerated),
    LastThrottle = max(TimeGenerated)
    by CallerName, CallerPriority
| order by ThrottledRequests desc'''

var qErrorBreakdown = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseCode >= 400
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| summarize Count = count() by ResponseCode, CallerName, bin(TimeGenerated, 1h)
| order by TimeGenerated desc'''

var qSpilloverSummary = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseHeaders has "x-caller-name"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| where isnotempty(CallerName)
| summarize
    FailoverCount = countif(IsFailover),
    TotalRequests  = count(),
    FirstFailover = minif(TimeGenerated, IsFailover),
    LastFailover  = maxif(TimeGenerated, IsFailover)
    by CallerName
| where FailoverCount > 0
| extend FailoverRate = round(100.0 * FailoverCount / TotalRequests, 1)
| project CallerName, FailoverCount, TotalRequests, FailoverRate, FirstFailover, LastFailover
| order by FailoverCount desc'''

var qSpilloverOverTime = '''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
ApiManagementGatewayLogs
| where TimeGenerated >= monthStart and TimeGenerated < monthEnd
| where ResponseHeaders has "x-inference-failover"
| extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend FailoverTrail = extract(@'"x-inference-failover":"([^"]+)"', 1, tostring(ResponseHeaders))
| extend IsFailover = isnotempty(FailoverTrail) and FailoverTrail != "none" and FailoverTrail != "false"
| where isnotempty(CallerName)
| summarize FailoverCount = countif(IsFailover) by bin(TimeGenerated, 1h), CallerName
| where FailoverCount > 0
| order by TimeGenerated asc'''

// ---------------------------------------------------------------------------
// SECTION 6 — Billed Cost (Cost Management → AICostData_CL)
// ---------------------------------------------------------------------------
// These queries read the custom table populated by the cost-ingestion Logic
// App (see infra/modules/dashboard/cost-ingestion.bicep). Rows include real
// billed cost per Foundry account, model meter, and Foundry `project` tag
// (Preview — Azure-direct models only; other rows land as "(untagged)").
// If DEPLOY_COST_INGESTION=false the table will exist empty and these tiles
// render "No data".

var qBilledTotal = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| summarize TotalBilledUsd = round(sum(BilledCost), 2),
            DistinctFoundries = dcount(FoundryResource),
            DistinctProjects  = dcount(Project),
            DistinctMeters    = dcount(Meter)''', '__COST_DATA__', costDataFrag)

var qBilledByFoundry = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| summarize BilledUsd = round(sum(BilledCost), 2) by FoundryResource
| order by BilledUsd desc''', '__COST_DATA__', costDataFrag)

var qBilledByProject = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| summarize BilledUsd = round(sum(BilledCost), 2),
            Foundries = make_set(FoundryResource, 20) by Project
| order by BilledUsd desc''', '__COST_DATA__', costDataFrag)

var qBilledByMeter = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| summarize BilledUsd = round(sum(BilledCost), 2) by Meter, ServiceName
| order by BilledUsd desc''', '__COST_DATA__', costDataFrag)

var qBilledDaily = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| summarize BilledUsd = round(sum(BilledCost), 2) by BillingDate, FoundryResource
| order by BillingDate asc''', '__COST_DATA__', costDataFrag)

// ---------------------------------------------------------------------------
// SECTION 7 — Hybrid Cost (LLM log tokens × Cost-Mgmt-derived rates)
// ---------------------------------------------------------------------------
// Combines near-real-time `ApiManagementGatewayLlmLog` (PromptTokens +
// CompletionTokens per request) with the effective USD-per-1M-token rate
// DERIVED from AICostData_CL (rate = BilledCost / UsageQuantity for the
// selected month). Delivers ~seconds-latency cost visibility using ACTUAL
// negotiated rates, without waiting for the daily Cost Mgmt tick.
//
// Why not AzureMetrics.TokenTransaction? Cognitive Services emits
// TokenTransaction with dimensions (ModelDeploymentName, TokenType) but the
// standard AzureMetrics table in Log Analytics does NOT expose those
// dimensions — only aggregates (Total/Count/Avg). So we use LLM log as the
// token source, which has full per-request granularity.
//
// Unit note: For Foundry token meters ("… 1M Tokens"), UsageQuantity is in
// units of 1,000,000 tokens, so UsdPerUnit is directly USD per 1M tokens.

// Per-Meter derived rate: USD per unit of UsageQuantity (≈ USD per 1M tokens
// for AOAI meters). Materialized because it's referenced by multiple tiles.
var qDerivedRates = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| where UsageQuantity > 0
| summarize BilledUsd = round(sum(BilledCost), 4),
            Units     = round(sum(UsageQuantity), 4)
    by Meter, FoundryResource, ServiceName
| extend UsdPerUnit = round(BilledUsd / Units, 4)
| order by BilledUsd desc''', '__COST_DATA__', costDataFrag)

// Foundry-level blended rate: sum(cost) / sum(qty) → effective USD per 1M
// tokens across all meters used by that Foundry. Robust — no Meter↔Model
// name matching required. This remains an estimate when one Foundry serves
// models or meters with materially different rates.
var qHybridFoundryRate = replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
costData
| where UsageQuantity > 0
| summarize BilledUsd = round(sum(BilledCost), 4),
            Units     = round(sum(UsageQuantity), 4),
            DistinctMeters = dcount(Meter)
    by FoundryResource
| extend BlendedUsdPer1MTokens = round(BilledUsd / Units, 4)
| order by BilledUsd desc''', '__COST_DATA__', costDataFrag)

// Hybrid real-time cost: LLM log tokens (near-real-time) × Foundry blended
// rate (derived from current-month bill). Per-Foundry × Model breakdown.
var qHybridCostByModel = replace(replace(replace('''let monthStart = todatetime("{SelectedMonth}");
let monthEnd = datetime_add("month", 1, monthStart);
__COST_DATA__
let blended = materialize(
    costData
    | where UsageQuantity > 0
    | summarize BilledUsd = sum(BilledCost), Units = sum(UsageQuantity)
        by FoundryKey = tolower(FoundryResource)
    | extend UsdPer1MTokens = BilledUsd / Units
    | project FoundryKey, UsdPer1MTokens
);
__FOUNDRY_JOIN__
__LLM_LOG__
llmLogDedup
| where isnotempty(DeploymentName)
| join kind=inner backendMap on CorrelationId
| extend ModelBase = tolower(replace_regex(ModelName, @"-\\d{4}-\\d{2}-\\d{2}$", ""))
| extend FoundryKey = tolower(FoundryAccount)
| summarize Requests = dcount(CorrelationId),
            PromptTokens = sum(PromptTokens),
            CompletionTokens = sum(CompletionTokens),
            TotalTokens = sum(PromptTokens) + sum(CompletionTokens)
    by FoundryKey, ModelBase
| join kind=leftouter blended on FoundryKey
| extend HybridCostUsd = round(coalesce(todouble(TotalTokens) / 1000000.0 * UsdPer1MTokens, 0.0), 4)
| project Foundry = FoundryKey,
          Model   = ModelBase,
          Requests, PromptTokens, CompletionTokens, TotalTokens,
          BlendedUsdPer1MTokens = round(coalesce(UsdPer1MTokens, 0.0), 4),
          HybridCostUsd
| order by HybridCostUsd desc''', '__FOUNDRY_JOIN__', foundryJoinFrag), '__LLM_LOG__', llmLogFrag), '__COST_DATA__', costDataFrag)

// ---------------------------------------------------------------------------
// Workbook body
// ---------------------------------------------------------------------------
var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    // ---- Header
    {
      type: 1
      content: {
        json: '## 🔒 AI Gateway — Monthly Report\n\nPer-caller, per-model, per-foundry token usage, estimated cost, backend distribution, and reliability metrics for any month in the last 12.\n\nData sources: `ApiManagementGatewayLlmLog` + `ApiManagementGatewayLogs` (both populated by the APIM `AllLogs` diagnostic-setting category).'
      }
      name: 'header'
    }
    // ---- Month dropdown
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          {
            id: 'month-param'
            version: 'KqlParameterItem/1.0'
            name: 'SelectedMonth'
            label: 'Month'
            type: 2
            isRequired: true
            query: 'range i from 0 to 11 step 1\n| project MonthStart = startofmonth(datetime_add("month", -i, now()))\n| project value = tostring(MonthStart), label = format_datetime(MonthStart, "yyyy-MM")'
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            crossComponentResources: [ logAnalyticsWorkspaceId ]
            typeSettings: { additionalResourceOptions: [], showDefault: false }
            value: 'value::0'
          }
        ]
        style: 'pills'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'parameters'
    }
    {
      type: 1
      content: { json: '### 📅 Reporting Period: **{SelectedMonth:label}**' }
      name: 'period-banner'
    }

    // =========================================================================
    // SECTION 1 — Caller Quota
    // =========================================================================
    { type: 1, content: { json: '---\n## 1️⃣ Caller Quota' }, name: 'sec-quota' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qQuotaOverview
        size: 0
        title: '📊 Caller Quota Overview'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-quota-overview'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qRemainingQuota
        size: 0
        title: '💰 Remaining Quota'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'QuotaUsedPct'
              formatter: 8
              formatOptions: { palette: 'redGreen', min: 0, max: 100 }
            }
          ]
        }
      }
      customWidth: '50'
      name: 't-remaining-quota'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBurnDown
        size: 0
        title: '🔥 Token Burn-Down (daily cumulative)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'linechart'
        // Chart-side running total — the KQL emits DAILY tokens per caller;
        // the workbook draws the cumulative curve. Doing cumsum in KQL AND
        // "Sum" here previously double-cumulated, hence the 553M inflation.
        chartSettings: {
          seriesLabelSettings: []
          xAxis: 'TimeGenerated'
          yAxis: [ 'DailyTokens' ]
          group: 'CallerName'
          createOtherGroup: 0
          ySettings: {
            numberFormatSettings: {
              unit: 17
              options: {
                style: 'decimal'
                useGrouping: true
                maximumFractionDigits: 0
              }
            }
            aggregation: 'RunningTotal'
          }
        }
      }
      name: 't-burn-down'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qDailyUsage
        size: 0
        title: '📅 Daily Usage by Caller'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-daily-usage'
    }

    // =========================================================================
    // SECTION 2 — Models
    // =========================================================================
    { type: 1, content: { json: '---\n## 2️⃣ Models' }, name: 'sec-models' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qModelUsage
        size: 0
        title: '🧠 Model Usage by Caller'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-model-usage'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qTokenUsageOverTime
        size: 0
        title: '📈 Token Usage Over Time by Caller (hourly)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [ 'TotalTokens' ]
          group: 'CallerName'
          seriesLabelSettings: []
        }
      }
      name: 't-usage-over-time'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qNonLlmEndpoints
        size: 0
        title: '🎙️ Non-LLM Endpoints (audio / images / embeddings)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-non-llm'
    }

    // =========================================================================
    // SECTION 3 — Foundries (NEW; not in dashboard)
    // =========================================================================
    { type: 1, content: { json: '---\n## 3️⃣ Foundries\n\nToken & cost breakdown per AI Foundry account that APIM routes to. Foundry account is derived from the backend hostname (`{foundry}.cognitiveservices.azure.com`).\n\n> **Cost** is sourced directly from `AICostData_CL` (real Azure Cost Management billing data). Meter names are mapped to model families via substring match (e.g. `5.4 nano Inp Gl 1M Tokens` → `gpt-5.4-nano`). Non-LLM meters like whisper and speech-to-text appear as-is. Requires the Cost Ingestion Logic App to have run.' }, name: 'sec-foundries' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qFoundryTokens
        size: 0
        title: '🏭 Foundry Token Consumption'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-foundry-tokens'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qFoundryCost
        size: 0
        title: '💵 Billed Cost by Foundry & Model (USD)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'BilledUsd'
              formatter: 8
              formatOptions: { palette: 'greenRed', min: 0 }
            }
          ]
        }
      }
      customWidth: '50'
      name: 't-foundry-cost'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qFoundryTokensOverTime
        size: 0
        title: '📈 Foundry Token Consumption Over Time (daily)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [ 'TotalTokens' ]
          group: 'FoundryAccount'
        }
      }
      name: 't-foundry-over-time'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qCallerCost
        size: 0
        title: '💵 Allocated Cost by Caller (USD)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-caller-cost'
    }

    // =========================================================================
    // SECTION 4 — Backends
    // =========================================================================
    { type: 1, content: { json: '---\n## 4️⃣ Backends' }, name: 'sec-backends' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBackendDistribution
        size: 0
        title: '🎯 Backend Distribution'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-backend-dist'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBackendOverTime
        size: 0
        title: '📊 Backend Requests Over Time (hourly)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [ 'Requests' ]
          group: 'BackendPool'
        }
      }
      name: 't-backend-over-time'
    }

    // =========================================================================
    // SECTION 5 — Reliability
    // =========================================================================
    { type: 1, content: { json: '---\n## 5️⃣ Reliability' }, name: 'sec-reliability' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qRateLimits
        size: 0
        title: '🚫 Rate Limit Events (429)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-rate-limits'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qErrorBreakdown
        size: 0
        title: '⚠️ Error Breakdown (4xx / 5xx)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-errors'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qSpilloverSummary
        size: 0
        title: '🌊 Inference Failover Summary'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-spillover-summary'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qSpilloverOverTime
        size: 0
        title: '📈 Inference Failover Over Time (hourly)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'linechart'
      }
      customWidth: '50'
      name: 't-spillover-over-time'
    }

    // =========================================================================
    // SECTION 6 — Billed Cost (real Cost Management data)
    // =========================================================================
    { type: 1, content: { json: '---\n## 6️⃣ Billed Cost\n\nReal billed cost pulled daily from Azure Cost Management by the Cost Ingestion Logic Apps into the `AICostData_CL` custom table. Collection is scoped to Foundries wired to this APIM deployment.\n\n> **Project attribution** relies on the Foundry `project` tag (Preview — Azure-direct models only). Rows without the tag land as `(untagged)` — this includes Marketplace models today.\n\n> **Same source as Section 3.** Section 3 breaks the same billed cost down by Foundry × ModelFamily; this section adds Project, Meter and daily-trend views on the same data.' }, name: 'sec-billed' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBilledTotal
        size: 3
        title: '💰 Total Billed (MTD)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'tiles'
        tileSettings: {
          titleContent: { columnMatch: 'TotalBilledUsd', formatter: 12, formatOptions: { palette: 'blue' } }
          leftContent: { columnMatch: 'DistinctFoundries', formatter: 12 }
          showBorder: true
        }
      }
      name: 't-billed-total'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBilledByFoundry
        size: 0
        title: '🏭 Billed Cost by Foundry'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'FoundryResource'
          yAxis: [ 'BilledUsd' ]
        }
      }
      customWidth: '50'
      name: 't-billed-foundry'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBilledByProject
        size: 0
        title: '📁 Billed Cost by Project (tag: project)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'Project'
          yAxis: [ 'BilledUsd' ]
        }
      }
      customWidth: '50'
      name: 't-billed-project'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBilledByMeter
        size: 0
        title: '📊 Billed Cost by Meter'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-billed-meter'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qBilledDaily
        size: 0
        title: '📈 Daily Billed Cost Trend'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'timechart'
        chartSettings: {
          xAxis: 'BillingDate'
          yAxis: [ 'BilledUsd' ]
          group: 'FoundryResource'
        }
      }
      customWidth: '50'
      name: 't-billed-daily'
    }

    // =========================================================================
    // SECTION 7 — Hybrid Cost (LLM log tokens × Cost-Mgmt-derived rates)
    // =========================================================================
    { type: 1, content: { json: '---\n## 7️⃣ Hybrid Cost (Real-Time with Actual Rates)\n\nNear-real-time cost combining `ApiManagementGatewayLlmLog` (per-request tokens, ~seconds latency) with the effective **USD per 1M tokens** rate *derived* from `AICostData_CL` (rate = BilledCost ÷ UsageQuantity for the selected month).\n\n> **Why not `AzureMetrics.TokenTransaction`?** Cognitive Services emits it with dimensions (`ModelDeploymentName`, `TokenType`) but the standard LAW `AzureMetrics` table strips those to aggregates only. LLM log has full granularity.\n\n> **Section 3 vs Section 6 vs Section 7.**  Section 3 = billed cost broken down by Foundry × ModelFamily (24h lag).  Section 6 = billed cost broken down by Project, Meter, and daily trend (same source, different cuts).  Section 7 = extrapolates cost mid-day from LlmLog tokens × current-month blended rate (seconds latency, useful for burn-rate alerts).\n\n> **Requires** `DEPLOY_COST_INGESTION=true`. Foundry token meters price per **1M tokens**, so `UsdPerUnit` from Cost Mgmt = USD per 1M tokens directly (no unit conversion needed for the join).' }, name: 'sec-hybrid' }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qDerivedRates
        size: 0
        title: '💵 Derived Rates by Meter (USD per 1M tokens, current-month effective)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-hybrid-rates'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qHybridFoundryRate
        size: 0
        title: '🏭 Foundry Blended Rate (USD per 1M tokens)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      customWidth: '50'
      name: 't-hybrid-foundry-rate'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: qHybridCostByModel
        size: 0
        title: '💰 Hybrid Real-Time Cost (LLM log tokens × blended rate)'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [ logAnalyticsWorkspaceId ]
        visualization: 'table'
      }
      name: 't-hybrid-cost'
    }
  ]
  fallbackResourceIds: [ logAnalyticsWorkspaceId ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookGuid
  location: location
  kind: 'shared'
  properties: {
    displayName: 'AI Gateway — Monthly Report'
    serializedData: string(workbookContent)
    version: '1.0'
    sourceId: logAnalyticsWorkspaceId
    category: 'workbook'
  }
}

output workbookId string = workbook.id
output workbookName string = workbook.name
