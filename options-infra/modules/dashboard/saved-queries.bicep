// Saved KQL Queries for Log Analytics Workspace
// These queries can be reused in dashboards, workbooks, and ad-hoc analysis

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

// ------------------
//    VARIABLES
// ------------------

// Extract workspace name from resource ID
var workspaceName = last(split(logAnalyticsWorkspaceId, '/'))

// ------------------
//    RESOURCES
// ------------------

// Saved Query: Token Usage by Subscription
resource queryTokenUsageBySubscription 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_TokenUsageBySubscription'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Token Usage by Subscription'
    query: '''
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
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Top Token Consumers
resource queryTopConsumers 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_TopTokenConsumers'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Top Token Consumers (Last 30 Days)'
    query: '''
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
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Daily Usage Summary
resource queryDailyUsage 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_DailyUsageSummary'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Daily Token Usage Summary'
    query: '''
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
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Model Usage Breakdown
resource queryModelUsage 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_ModelUsageBreakdown'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Model/Deployment Usage Breakdown'
    query: '''
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
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Hourly Token Trend
resource queryHourlyTrend 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_HourlyTokenTrend'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Hourly Token Usage Trend'
    query: '''
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1h), SubscriptionName = ApimSubscriptionId
| order by TimeGenerated asc
'''
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Subscription Usage Details
resource querySubscriptionDetails 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_SubscriptionUsageDetails'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Subscription Usage Details'
    query: '''
let subscriptionId = "YOUR_SUBSCRIPTION_ID"; // Replace with actual subscription ID
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != '';
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| where ApimSubscriptionId == subscriptionId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    Requests = count()
by bin(TimeGenerated, 1d), DeploymentName
| order by TimeGenerated desc
'''
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// Saved Query: Cost Estimation (FinOps Framework)
resource queryCostEstimation 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  name: '${workspaceName}/APIM_CostEstimation'
  properties: {
    category: 'APIM Token Analytics'
    displayName: 'Estimated Token Cost'
    query: '''
// Cost estimation based on typical Azure OpenAI pricing
// Adjust rates based on your actual pricing tier
let prompt_rate_per_1k = 0.001; // $0.001 per 1K prompt tokens
let completion_rate_per_1k = 0.002; // $0.002 per 1K completion tokens
ApiManagementGatewayLlmLog
| where DeploymentName != ''
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens)
by SubscriptionId = ApimSubscriptionId, DeploymentName
| extend
    EstPromptCost = round(PromptTokens * prompt_rate_per_1k / 1000, 4),
    EstCompletionCost = round(CompletionTokens * completion_rate_per_1k / 1000, 4)
| extend EstTotalCost = EstPromptCost + EstCompletionCost
| project SubscriptionId, DeploymentName, PromptTokens, CompletionTokens, TotalTokens, EstPromptCost, EstCompletionCost, EstTotalCost
| order by EstTotalCost desc
'''
    version: 2
    tags: [
      {
        name: 'Group'
        value: 'APIM FinOps'
      }
    ]
  }
}

// ------------------
//    OUTPUTS
// ------------------

output savedQueriesDeployed array = [
  queryTokenUsageBySubscription.name
  queryTopConsumers.name
  queryDailyUsage.name
  queryModelUsage.name
  queryHourlyTrend.name
  querySubscriptionDetails.name
  queryCostEstimation.name
]
