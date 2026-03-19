// ============================================================================
// AI Gateway — JWT Citadel with 3-Priority PTU Routing
// ============================================================================
// Thin orchestrator that wires together:
//   1. Entra ID app registrations (gateway + N team apps from contracts)
//   2. Log Analytics + Application Insights
//   3. AI Gateway Advanced module (APIM + priority routing + contract storage)
//   4. Cross-RG role assignments (APIM → Foundry instances)
//   5. Monitoring dashboard
// ============================================================================
targetScope = 'resourceGroup'

import { foundryInstanceType, accessContractType } from '../modules/apim/advanced/types.bicep'

// -- Parameters ---------------------------------------------------------------

param location string = resourceGroup().location

@description('Array of existing Foundry/OpenAI instances to register as backends')
param foundryInstances foundryInstanceType[]

@description('Access contracts defining team identities, priorities, and quotas')
param accessContracts accessContractType[]

// -- Variables ----------------------------------------------------------------

var tags = {
  'created-by': 'ai-gateway-quota-priority'
  'hidden-title': 'APIM AI Gateway — JWT Citadel with Priority Routing'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// -- Validation ---------------------------------------------------------------
var validConfig = empty(foundryInstances)
  ? fail('At least one Foundry instance must be provided in foundryInstances parameter.')
  : empty(accessContracts)
      ? fail('At least one access contract must be provided in accessContracts parameter.')
      : true

// ============================================================================
// -- Entra ID App Registrations
// ============================================================================
module entraApps 'entra/entra-apps-dynamic.bicep' = {
  name: 'entra-apps-deployment'
  params: {
    appNamePrefix: 'ai-gw-priority-${resourceToken}'
    contracts: accessContracts
  }
}

// ============================================================================
// -- Log Analytics + App Insights
// ============================================================================
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

// ============================================================================
// -- Event Hub (quota-exceeded notifications)
// ============================================================================
module eventHub '../modules/eventhub/eventhub.bicep' = {
  name: 'eventhub-deployment'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceToken
    hubName: 'quota-events'
    namespaceName: 'quota-events-ns-${resourceToken}'
  }
}

// ============================================================================
// -- AI Gateway (APIM + priority routing + contract storage + inference API)
// ============================================================================
module aiGateway '../modules/apim/ai-gateway-advanced.bicep' = {
  name: 'ai-gateway-advanced'
  params: {
    location: location
    tags: tags
    resourceToken: resourceToken
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    foundryInstances: foundryInstances
    accessContracts: entraApps.outputs.contractsWithIdentities
    eventHubNamespaceName: eventHub.outputs.namespaceName
    eventHubName: eventHub.outputs.eventHubName
  }
}

// ============================================================================
// -- Role Assignments: APIM → each Foundry instance (cross-RG)
// ============================================================================
@batchSize(1)
module apimRoleAssignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in foundryInstances: {
    name: 'apim-role-${instance.name}-${resourceToken}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: aiGateway.outputs.apimPrincipalId
      roleName: 'Cognitive Services User'
    }
  }
]

// ============================================================================
// -- Dashboard
// ============================================================================
module quotaDashboard 'dashboard/dashboard.bicep' = {
  name: 'quota-dashboard-deployment'
  params: {
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    callerTierMapping: aiGateway.outputs.contractMapJson
  }
}

// ============================================================================
// -- Outputs
// ============================================================================
output APIM_GATEWAY_URL string = aiGateway.outputs.apimGatewayUrl
output APIM_API_URL string = aiGateway.outputs.inferenceApiUrl
output APIM_CONFIG_URL string = aiGateway.outputs.configViewerUrl
output APIM_NAME string = aiGateway.outputs.apimName
output GATEWAY_APP_ID string = entraApps.outputs.gatewayAppId
output GATEWAY_AUDIENCE string = entraApps.outputs.gatewayAudience
output TENANT_ID string = entraApps.outputs.tenantId
output CONTRACTS_BLOB_URL string = aiGateway.outputs.contractsBlobUrl
output POOL_NAMES array = aiGateway.outputs.poolNames
output HAS_PTU_DEPLOYMENTS bool = aiGateway.outputs.hasPtuDeployments
output CONFIG_VALIDATION_RESULT bool = validConfig
output CREATED_APP_IDS array = entraApps.outputs.createdAppIds
output EVENTHUB_NAMESPACE string = eventHub.outputs.namespaceName
output EVENTHUB_NAME string = eventHub.outputs.eventHubName
