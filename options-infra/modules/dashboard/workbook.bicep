// Azure Workbook for APIM Token Usage Analysis
// Provides interactive, detailed analytics following FinOps framework

@description('Location for the workbook')
param location string

@description('Workbook display name')
param workbookDisplayName string

@description('Log Analytics Workspace resource ID')
param logAnalyticsWorkspaceId string

// ------------------
//    VARIABLES
// ------------------

var workbookId = guid(resourceGroup().id, 'apim-token-workbook')

// Workbook JSON content with KQL queries
var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    // Header
    {
      type: 1
      content: {
        json: '# 🤖 APIM Token Usage Analytics\n\nInteractive workbook for analyzing LLM token consumption across your API Management subscriptions.\n\n---'
      }
      name: 'header'
    }
    // Time Range Parameter
    {
      type: 9
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          {
            id: 'timeRange'
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            type: 4
            isRequired: true
            value: {
              durationMs: 604800000
            }
            typeSettings: {
              selectableValues: [
                { durationMs: 3600000 }
                { durationMs: 14400000 }
                { durationMs: 43200000 }
                { durationMs: 86400000 }
                { durationMs: 172800000 }
                { durationMs: 259200000 }
                { durationMs: 604800000 }
                { durationMs: 1209600000 }
                { durationMs: 2592000000 }
              ]
            }
            label: 'Time Range'
          }
          {
            id: 'subscription'
            version: 'KqlParameterItem/1.0'
            name: 'SubscriptionFilter'
            type: 2
            isRequired: false
            multiSelect: true
            quote: '\''
            delimiter: ','
            query: '''
              ApiManagementGatewayLogs
              | distinct ApimSubscriptionId
              | where isnotempty(ApimSubscriptionId)
              | order by ApimSubscriptionId asc
            '''
            typeSettings: {
              additionalResourceOptions: [
                'value::all'
              ]
            }
            defaultValue: 'value::all'
            queryType: 0
            resourceType: 'microsoft.operationalinsights/workspaces'
            label: 'Subscription'
          }
        ]
        style: 'pills'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
      }
      name: 'parameters'
    }
    // Overview Stats
    {
      type: 1
      content: {
        json: '## 📊 Overview'
      }
      name: 'overview-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          ApiManagementGatewayLlmLog
          | where DeploymentName != ''
          | summarize
              TotalTokens = sum(TotalTokens),
              PromptTokens = sum(PromptTokens),
              CompletionTokens = sum(CompletionTokens),
              TotalRequests = count()
        '''
        size: 3
        title: 'Total Usage Summary'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'tiles'
        tileSettings: {
          titleContent: {
            columnMatch: 'Column1'
            formatter: 1
          }
          leftContent: {
            columnMatch: 'TotalTokens'
            formatter: 12
            formatOptions: {
              palette: 'auto'
            }
            numberFormat: {
              unit: 17
              options: {
                style: 'decimal'
                maximumFractionDigits: 0
              }
            }
          }
          showBorder: true
        }
      }
      name: 'overview-stats'
    }
    // Token Usage Over Time
    {
      type: 1
      content: {
        json: '## 📈 Token Usage Trends'
      }
      name: 'trends-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          let llmHeaderLogs = ApiManagementGatewayLlmLog
          | where DeploymentName != '';
          llmHeaderLogs
          | join kind=leftouter ApiManagementGatewayLogs on CorrelationId
          | where ApimSubscriptionId in ({SubscriptionFilter}) or '*' in ({SubscriptionFilter})
          | summarize TotalTokens = sum(TotalTokens) by bin(TimeGenerated, 1h), SubscriptionName = ApimSubscriptionId
          | order by TimeGenerated asc
        '''
        size: 0
        title: 'Hourly Token Usage by Subscription'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'areachart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [
            'TotalTokens'
          ]
          group: 'SubscriptionName'
          createOtherGroup: 5
          showLegend: true
        }
      }
      name: 'hourly-usage-chart'
    }
    // Prompt vs Completion Tokens
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          ApiManagementGatewayLlmLog
          | where DeploymentName != ''
          | summarize
              PromptTokens = sum(PromptTokens),
              CompletionTokens = sum(CompletionTokens)
          by bin(TimeGenerated, 1d)
          | order by TimeGenerated asc
        '''
        size: 0
        title: 'Prompt vs Completion Tokens (Daily)'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'barchart'
        chartSettings: {
          xAxis: 'TimeGenerated'
          yAxis: [
            'PromptTokens'
            'CompletionTokens'
          ]
          showLegend: true
        }
      }
      name: 'prompt-completion-chart'
    }
    // Subscription Analysis
    {
      type: 1
      content: {
        json: '## 🏆 Subscription Analysis'
      }
      name: 'subscription-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          let llmHeaderLogs = ApiManagementGatewayLlmLog
          | where DeploymentName != '';
          llmHeaderLogs
          | join kind=leftouter ApiManagementGatewayLogs on CorrelationId
          | summarize
              PromptTokens = sum(PromptTokens),
              CompletionTokens = sum(CompletionTokens),
              TotalTokens = sum(TotalTokens),
              Requests = count()
          by SubscriptionName = ApimSubscriptionId, DeploymentName
          | order by TotalTokens desc
        '''
        size: 0
        title: 'Usage by Subscription & Model'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'TotalTokens'
              formatter: 3
              formatOptions: {
                palette: 'blue'
              }
            }
            {
              columnMatch: 'Requests'
              formatter: 3
              formatOptions: {
                palette: 'green'
              }
            }
          ]
        }
      }
      name: 'subscription-table'
    }
    // Top Consumers Pie Chart
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          let llmHeaderLogs = ApiManagementGatewayLlmLog
          | where DeploymentName != '';
          llmHeaderLogs
          | join kind=leftouter ApiManagementGatewayLogs on CorrelationId
          | summarize TotalTokens = sum(TotalTokens) by SubscriptionId = ApimSubscriptionId
          | top 10 by TotalTokens desc
        '''
        size: 0
        title: 'Top 10 Token Consumers'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'piechart'
      }
      name: 'top-consumers-pie'
    }
    // Model Analysis
    {
      type: 1
      content: {
        json: '## 🧠 Model/Deployment Analysis'
      }
      name: 'model-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          ApiManagementGatewayLlmLog
          | where DeploymentName != ''
          | summarize
              PromptTokens = sum(PromptTokens),
              CompletionTokens = sum(CompletionTokens),
              TotalTokens = sum(TotalTokens),
              Requests = count(),
              AvgTokensPerRequest = avg(TotalTokens)
          by DeploymentName, ModelName
          | order by TotalTokens desc
        '''
        size: 0
        title: 'Usage by Model/Deployment'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'TotalTokens'
              formatter: 3
              formatOptions: {
                palette: 'purple'
              }
            }
          ]
        }
      }
      name: 'model-table'
    }
    // Model Distribution
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          ApiManagementGatewayLlmLog
          | where DeploymentName != ''
          | summarize TotalTokens = sum(TotalTokens) by DeploymentName
        '''
        size: 0
        title: 'Token Distribution by Model'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'piechart'
      }
      name: 'model-pie'
    }
    // Cost Estimation
    {
      type: 1
      content: {
        json: '## 💰 Cost Estimation\n\n> **Note**: Costs are estimated based on typical Azure OpenAI pricing. Adjust the rates in the query for your specific pricing tier.'
      }
      name: 'cost-header'
    }
    {
      type: 3
      content: {
        version: 'KqlItem/1.0'
        query: '''
          let prompt_rate_per_1k = 0.001;
          let completion_rate_per_1k = 0.002;
          ApiManagementGatewayLlmLog
          | where DeploymentName != ''
          | join kind=leftouter ApiManagementGatewayLogs on CorrelationId
          | summarize
              PromptTokens = sum(PromptTokens),
              CompletionTokens = sum(CompletionTokens),
              TotalTokens = sum(TotalTokens)
          by SubscriptionId = ApimSubscriptionId
          | extend
              EstPromptCost = round(PromptTokens * prompt_rate_per_1k / 1000, 4),
              EstCompletionCost = round(CompletionTokens * completion_rate_per_1k / 1000, 4)
          | extend EstTotalCost = EstPromptCost + EstCompletionCost
          | project SubscriptionId, PromptTokens, CompletionTokens, TotalTokens, EstPromptCost, EstCompletionCost, EstTotalCost
          | order by EstTotalCost desc
        '''
        size: 0
        title: 'Estimated Cost by Subscription'
        timeContext: {
          durationMs: 0
        }
        timeContextFromParameter: 'TimeRange'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        visualization: 'table'
        gridSettings: {
          formatters: [
            {
              columnMatch: 'EstTotalCost'
              formatter: 3
              formatOptions: {
                palette: 'orange'
              }
              numberFormat: {
                unit: 0
                options: {
                  style: 'currency'
                  currency: 'USD'
                }
              }
            }
          ]
        }
      }
      name: 'cost-table'
    }
  ]
  fallbackResourceIds: [
    logAnalyticsWorkspaceId
  ]
}

// ------------------
//    RESOURCES
// ------------------

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = {
  name: workbookId
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: string(workbookContent)
    version: '1.0'
    sourceId: logAnalyticsWorkspaceId
    category: 'workbook'
  }
  tags: {
    'hidden-title': workbookDisplayName
  }
}

// ------------------
//    OUTPUTS
// ------------------

output workbookId string = workbook.id
output workbookName string = workbook.name
