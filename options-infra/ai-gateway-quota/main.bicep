// This bicep deploys an APIM AI Gateway with:
// 1. Entra ID app registrations (gateway + 3 team apps with azp-based identity)
// 2. Bearer token (JWT) authentication via validate-azure-ad-token
// 3. Caller identification via azp claim extraction
// 4. Authorization check against a configurable allow-list (Named Value)
// 5. Per-caller token quota enforcement using azure-openai-token-limit
// 6. Tiered quota model (Gold: 200K TPM / Silver: 50K TPM / Bronze: 10K TPM)
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param openAiApiBase string
param openAiResourceId string
param openAiLocation string = location

var tags = {
  'created-by': 'option-ai-gateway-quota'
  'hidden-title': 'APIM AI Gateway - Bearer Auth + Quota Tiers'
  SecurityControl: 'Ignore'
}

var valid_config = empty(openAiApiBase) || empty(openAiResourceId)
  ? fail('OPENAI_API_BASE and OPENAI_RESOURCE_ID environment variables must be set.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var openAiParts = split(openAiResourceId, '/')
var openAiName = last(openAiParts)
var openAiSubscriptionId = openAiParts[2]
var openAiResourceGroupName = openAiParts[4]

// --------------------------------------------------------------------------------------------------------------
// -- Entra ID App Registrations --------------------------------------------------------------------------------
// -- Gateway app (audience) + 3 team apps (callers with azp claims)                                           --
// -- Client secrets are created post-deploy via scripts/add_app_reg_secret.sh                                 --
// --------------------------------------------------------------------------------------------------------------
module entraApps 'entra/entra-apps.bicep' = {
  name: 'entra-apps-deployment'
  params: {
    appNamePrefix: 'ai-gw-quota-${resourceToken}'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- APIM Instance ---------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module apim '../modules/apim/v2/apim.bicep' = {
  name: 'apim-v2'
  params: {
    location: location
    tags: tags
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    resourceSuffix: resourceToken
    apimSku: 'Basicv2'
    apimSubscriptionsConfig: [] // No subscription keys - auth is via JWT bearer token
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Named Value: Caller Tier Mapping --------------------------------------------------------------------------
// -- This stores the azp → {tier, name} JSON mapping that the policy reads at request time                    --
// --------------------------------------------------------------------------------------------------------------
resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: 'apim-${resourceToken}'
}

resource callerTierMappingNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimService
  name: 'caller-tier-mapping'
  dependsOn: [apim]
  properties: {
    displayName: 'caller-tier-mapping'
    value: entraApps.outputs.callerTierMapping
    secret: false
    tags: ['quota', 'caller-mapping']
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Policy XML ------------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
var backendId = '${openAiName}-AzureOpenAI-backend'

var policyXml = replace(
  replace(
    replace(
      loadTextContent('policy_quota.xml'),
      '{tenant-id}',
      subscription().tenantId
    ),
    '{audience}',
    entraApps.outputs.gatewayAudience
  ),
  '{backend-id}',
  backendId
)

// --------------------------------------------------------------------------------------------------------------
// -- Inference API (no subscription key required - auth is JWT) ------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
resource inferenceApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimService
  name: 'inference-api'
  dependsOn: [apim]
  properties: {
    apiType: 'http'
    description: 'AI Gateway with Bearer Token Auth and Quota Tiers'
    displayName: 'AI Gateway - Quota'
    format: 'openapi+json'
    path: 'inference/openai'
    protocols: [
      'https'
    ]
    subscriptionRequired: false // Auth is via JWT bearer token, not subscription keys
    type: 'http'
    value: string(loadJsonContent('../modules/apim/v2/specs/AIFoundryOpenAI.json'))
  }
}

resource inferenceApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: inferenceApi
  name: 'policy'
  dependsOn: [callerTierMappingNamedValue]
  properties: {
    format: 'rawxml'
    value: policyXml
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Backend: Azure OpenAI -------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
resource openAiBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apimService
  name: backendId
  dependsOn: [apim]
  properties: {
    description: 'Azure OpenAI backend for ${openAiName}'
    url: '${openAiApiBase}openai'
    protocol: 'http'
    circuitBreaker: {
      rules: [
        {
          failureCondition: {
            count: 1
            errorReasons: [
              'Server errors'
            ]
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
            ]
          }
          name: 'InferenceBreakerRule'
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
    credentials: {
      #disable-next-line BCP037
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    }
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- API Diagnostics -------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
var logSettings = {
  headers: ['Content-type', 'User-agent', 'x-ms-region', 'x-ratelimit-remaining-tokens', 'x-caller-azp', 'x-caller-name', 'x-caller-tier']
  body: { bytes: 8192 }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = {
  parent: inferenceApi
  name: 'azuremonitor'
  properties: {
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    logClientIp: true
    loggerId: apim.outputs.loggerId
    sampling: {
      samplingType: 'fixed'
      percentage: json('100')
    }
    frontend: {
      request: logSettings
      response: {
        headers: []
        body: { bytes: 0 }
      }
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Role Assignment: APIM → Azure OpenAI (Cognitive Services User) -------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module apim_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: 'apim-role-assignment-deployment-${resourceToken}'
  scope: resourceGroup(openAiSubscriptionId, openAiResourceGroupName)
  params: {
    accountName: openAiName
    projectPrincipalId: apim.outputs.principalId
    roleName: 'Cognitive Services User'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Named Value: Blocked Callers (monthly budget enforcement) ------------------------------------------------
// -- Updated atomically by Logic App when callers exceed monthly token budgets                               --
// --------------------------------------------------------------------------------------------------------------
resource blockedCallersNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimService
  name: 'blocked-callers'
  dependsOn: [apim]
  properties: {
    displayName: 'blocked-callers'
    value: '{}'
    secret: false
    tags: ['quota', 'monthly-budget']
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Custom Log Analytics Table: CALLER_QUOTA_CL (monthly token budgets per caller) ---------------------------
// --------------------------------------------------------------------------------------------------------------
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'log-analytics'
}

resource callerQuotaTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: logAnalyticsWorkspace
  name: 'CALLER_QUOTA_CL'
  dependsOn: [logAnalytics]
  properties: {
    totalRetentionInDays: 365
    plan: 'Analytics'
    schema: {
      name: 'CALLER_QUOTA_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'CallerAzp', type: 'string', description: 'Application (client) ID' }
        { name: 'CallerName', type: 'string', description: 'Human-readable caller name' }
        { name: 'MonthlyTokenBudget', type: 'long', description: 'Monthly token budget limit' }
      ]
    }
    retentionInDays: 365
  }
}

// Data Collection Rule for CALLER_QUOTA_CL ingestion
resource callerQuotaDCR 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-caller-quota-${resourceToken}'
  location: location
  tags: tags
  dependsOn: [callerQuotaTable]
  kind: 'Direct'
  properties: {
    streamDeclarations: {
      'Custom-Json-CALLER_QUOTA_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'CallerAzp', type: 'string' }
          { name: 'CallerName', type: 'string' }
          { name: 'MonthlyTokenBudget', type: 'long' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: logAnalyticsWorkspace.name
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-Json-CALLER_QUOTA_CL']
        destinations: [logAnalyticsWorkspace.name]
        transformKql: 'source'
        outputStream: 'Custom-CALLER_QUOTA_CL'
      }
    ]
  }
}

// Role: Monitoring Metrics Publisher on DCR (for data ingestion)
var monitoringMetricsPublisherRoleId = resourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: callerQuotaDCR
  name: guid(callerQuotaDCR.id, monitoringMetricsPublisherRoleId, 'deployer')
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Logic App: Update blocked-callers Named Value when budget exceeded ---------------------------------------
// --------------------------------------------------------------------------------------------------------------
resource budgetEnforcementLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: 'la-budget-enforcement-${resourceToken}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        When_budget_alert_fires: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              properties: {
                schemaId: { type: 'string' }
                data: {
                  type: 'object'
                  properties: {
                    essentials: { type: 'object' }
                    alertContext: { type: 'object' }
                  }
                }
              }
            }
          }
        }
      }
      actions: {
        Parse_alert_results: {
          type: 'ParseJson'
          inputs: {
            content: '@triggerBody()?[\'data\']?[\'alertContext\']?[\'condition\']?[\'allOf\']?[0]?[\'searchResult\']?[\'tables\']?[0]?[\'rows\']'
            schema: {
              type: 'array'
              items: {
                type: 'array'
              }
            }
          }
          runAfter: {}
        }
        Build_blocked_callers_json: {
          type: 'Compose'
          inputs: '@body(\'Parse_alert_results\')'
          runAfter: {
            Parse_alert_results: ['Succeeded']
          }
        }
        Build_named_value_body: {
          type: 'Compose'
          // Build the JSON: {azp: {reason, name, blocked_at}} for each over-budget caller
          // Alert query returns: CallerAzp, CallerName, MonthlyUsage, MonthlyBudget
          inputs: '@json(concat(\'{\', join(body(\'Parse_alert_results\'), \',\'), \'}\'))'
          runAfter: {
            Build_blocked_callers_json: ['Succeeded']
          }
        }
        Update_APIM_Named_Value: {
          type: 'Http'
          inputs: {
            uri: '${environment().resourceManager}${apimService.id}/namedValues/blocked-callers?api-version=2024-06-01-preview'
            method: 'PATCH'
            body: {
              properties: {
                value: '@{body(\'Build_named_value_body\')}'
              }
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: '${environment().resourceManager}'
            }
          }
          runAfter: {
            Build_named_value_body: ['Succeeded']
          }
        }
        Send_200_response: {
          type: 'Response'
          inputs: {
            statusCode: 200
            body: {
              status: 'Named value updated'
            }
          }
          runAfter: {
            Update_APIM_Named_Value: ['Succeeded']
          }
        }
      }
    }
  }
}

// Role: API Management Service Contributor on APIM (for Logic App to update Named Values)
var apimServiceContributorRoleId = resourceId('Microsoft.Authorization/roleDefinitions', '312a565d-c81f-4fd8-895a-4e21e48d571c')
resource logicAppApimRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: apimService
  name: guid(apimService.id, apimServiceContributorRoleId, budgetEnforcementLogicApp.id)
  properties: {
    roleDefinitionId: apimServiceContributorRoleId
    principalId: budgetEnforcementLogicApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Action Group to trigger Logic App
resource budgetActionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: 'ag-budget-enforcement-${resourceToken}'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'BudgetEnf'
    enabled: true
    logicAppReceivers: [
      {
        name: 'budget-enforcement-logic-app'
        resourceId: budgetEnforcementLogicApp.id
        callbackUrl: listCallbackURL('${budgetEnforcementLogicApp.id}/triggers/When_budget_alert_fires', '2019-05-01').value
        useCommonAlertSchema: true
      }
    ]
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Scheduled KQL Alert: Monthly Budget Enforcement ----------------------------------------------------------
// -- Runs every 5 minutes, checks if any caller has exceeded their monthly token budget                      --
// --------------------------------------------------------------------------------------------------------------
resource budgetAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-budget-exceeded-${resourceToken}'
  location: location
  tags: tags
  properties: {
    displayName: 'Monthly Token Budget Exceeded'
    description: 'Fires when a caller exceeds their monthly token budget. Triggers Logic App to block the caller.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'P31D'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
// Monthly usage per caller from LLM logs
let monthlyUsage = ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| join kind=leftouter (
    ApiManagementGatewayLogs
    | where BackendRequestHeaders has "x-caller-azp"
    | extend CallerAzp = extract(@'"x-caller-azp":"([^"]+)"', 1, tostring(BackendRequestHeaders))
    | extend CallerName = extract(@'"x-caller-name":"([^"]+)"', 1, tostring(BackendRequestHeaders))
    | project CorrelationId, CallerAzp, CallerName
) on CorrelationId
| summarize MonthlyUsage = sum(TotalTokens) by CallerAzp, CallerName;
// Join with budget table
let budgets = CALLER_QUOTA_CL
| summarize arg_max(TimeGenerated, *) by CallerAzp
| project CallerAzp, CallerName, MonthlyTokenBudget;
// Find over-budget callers — output formatted for Logic App
monthlyUsage
| join kind=inner budgets on CallerAzp
| where MonthlyUsage > MonthlyTokenBudget
| project CallerAzp, CallerName=CallerName, MonthlyUsage, MonthlyTokenBudget
'''
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'CallerAzp'
              operator: 'Include'
              values: ['*']
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        budgetActionGroup.id
      ]
    }
  }
}

// Monthly reset alert — clears blocked-callers at month start
resource monthlyResetAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-monthly-reset-${resourceToken}'
  location: location
  tags: tags
  properties: {
    displayName: 'Monthly Quota Reset'
    description: 'At the start of each month, re-evaluates budgets. If no callers are over budget, the blocked list is cleared.'
    severity: 3
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P1D'
    scopes: [
      logAnalyticsWorkspace.id
    ]
    criteria: {
      allOf: [
        {
          query: '''
// This query returns results only on the first day of the month when no callers are over budget
// (i.e., the blocked list should be empty)
let isFirstDay = startofday(now()) == startofmonth(now());
let overBudget = ApiManagementGatewayLlmLog
| where TimeGenerated >= startofmonth(now())
| summarize MonthlyUsage = sum(TotalTokens) by CorrelationId
| count;
print IsFirstDay=isFirstDay, OverBudgetCount=toscalar(overBudget)
| where IsFirstDay == true and OverBudgetCount == 0
'''
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Count'
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        budgetActionGroup.id
      ]
    }
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Dashboard: Quota Tiers -----------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module quotaDashboard 'dashboard/dashboard.bicep' = {
  name: 'quota-dashboard-deployment'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    callerTierMapping: entraApps.outputs.callerTierMapping
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Outputs ---------------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output APIM_API_URL string = '${apim.outputs.gatewayUrl}/inference/openai'
output APIM_NAME string = apim.outputs.name
output GATEWAY_APP_ID string = entraApps.outputs.gatewayAppId
output GATEWAY_AUDIENCE string = entraApps.outputs.gatewayAudience
output TEAM_ALPHA_APP_ID string = entraApps.outputs.teamAlphaAppId
output TEAM_BETA_APP_ID string = entraApps.outputs.teamBetaAppId
output TEAM_GAMMA_APP_ID string = entraApps.outputs.teamGammaAppId
output TENANT_ID string = entraApps.outputs.tenantId
output CONFIG_VALIDATION_RESULT bool = valid_config
output DCR_ENDPOINT string = callerQuotaDCR.properties.dataCollectionEndpointId ?? ''
output DCR_IMMUTABLE_ID string = callerQuotaDCR.properties.immutableId
