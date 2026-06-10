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
import { aiModelTDeploymentType } from '../modules/ai/ai-foundry.bicep'

// -- Parameters ---------------------------------------------------------------

param location string = resourceGroup().location

@description('Array of existing Foundry/OpenAI instances to register as backends (BYO mode). Leave empty to use self-contained mode.')
param foundryInstances foundryInstanceType[] = []

@description('Access contracts defining team identities, priorities, and quotas')
param accessContracts accessContractType[]

@description('Store contracts in Azure Blob Storage (true) or APIM Named Value (false). Named Value has a 4096-char limit — use Blob Storage for larger contract sets.')
param useStorageAccount bool = true

@description('Optional: deploy a self-contained Foundry account in this resource group with these model deployments, and auto-register it as a PAYG backend. Empty means BYO via foundryInstances.')
param createFoundryDeployments aiModelTDeploymentType[] = []

// -- Variables ----------------------------------------------------------------

var tags = {
  'created-by': 'ai-gateway-quota-priority'
  'hidden-title': 'APIM AI Gateway — Quota Access Contracts'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var selfFoundryName = 'aif-${resourceToken}'

// -- Validation ---------------------------------------------------------------
var hasAnyFoundry = !empty(foundryInstances) || !empty(createFoundryDeployments)
var validConfig = !hasAnyFoundry
  ? fail('Provide either foundryInstances (BYO) or createFoundryDeployments (self-contained).')
  : empty(accessContracts)
      ? fail('At least one access contract must be provided in accessContracts parameter.')
      : true

// ============================================================================
// -- Self-Contained Foundry (optional)
// ============================================================================
module selfFoundry '../modules/ai/ai-foundry.bicep' = if (!empty(createFoundryDeployments)) {
  name: 'self-foundry-deployment'
  params: {
    name: selfFoundryName
    location: location
    tags: tags
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    deployments: createFoundryDeployments
  }
}

// Build the synthesized PAYG instance for the self-hosted Foundry.
// `resourceId` and `endpoint` reference the module output directly (this is
// evaluated only when the array is non-empty downstream).
var selfFoundryInstance = !empty(createFoundryDeployments)
  ? [
      {
        name: selfFoundryName
        resourceId: selfFoundry!.outputs.FOUNDRY_RESOURCE_ID
        endpoint: selfFoundry!.outputs.FOUNDRY_ENDPOINT
        location: location
        isPtu: false
        deployments: map(createFoundryDeployments, d => { modelName: d.name })
      }
    ]
  : []

var effectiveFoundryInstances = concat(foundryInstances, selfFoundryInstance)

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
    foundryInstances: effectiveFoundryInstances
    accessContracts: entraApps.outputs.contractsWithIdentities
    eventHubNamespaceName: eventHub.outputs.namespaceName
    eventHubName: eventHub.outputs.eventHubName
    useStorageAccount: useStorageAccount
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

// Role assignment for the self-hosted Foundry (same RG).
module apimRoleSelfFoundry '../modules/iam/role-assignment-cognitiveServices.bicep' = if (!empty(createFoundryDeployments)) {
  name: 'apim-role-${selfFoundryName}-${resourceToken}'
  params: {
    accountName: selfFoundryName
    principalId: aiGateway.outputs.apimPrincipalId
    roleName: 'Cognitive Services User'
  }
  dependsOn: [
    selfFoundry
  ]
}

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
output CONTRACTS_STORAGE_MODE string = useStorageAccount ? 'blob' : 'named-value'
output POOL_NAMES array = aiGateway.outputs.poolNames
output HAS_PTU_DEPLOYMENTS bool = aiGateway.outputs.hasPtuDeployments
output CONFIG_VALIDATION_RESULT bool = validConfig
output CREATED_APP_IDS array = entraApps.outputs.createdAppIds
output EVENTHUB_NAMESPACE string = eventHub.outputs.namespaceName
output EVENTHUB_NAME string = eventHub.outputs.eventHubName
