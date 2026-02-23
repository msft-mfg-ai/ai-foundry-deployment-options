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
