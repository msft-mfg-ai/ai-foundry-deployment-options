// ============================================================================
// AI Gateway — Advanced (JWT Citadel with Priority Routing)
// ============================================================================
// Extension of the base AI Gateway that adds:
//   - JWT-only auth (no subscription keys) via Entra ID tokens
//   - Per-team access contracts with priority routing (P1 Production / P3 Economy)
//   - Per-model PTU-only and PAYG-only backend pools
//   - Per-model and per-team TPM quotas + monthly cost caps
//   - Two-API loopback: PTU gate with atomic llm-token-limit, retry fallback to PAYG
//   - Per-project Foundry connections (identity-based, optional)
//
// Uses: v2/apim.bicep (APIM service), v2/inference-api.bicep (inference API)
// Adds: advanced/contract-storage, advanced/multi-foundry-backends, priority policy
// ============================================================================

import { ModelType } from '../ai/connection-apim-gateway.bicep'
import {
  foundryInstanceType
  accessContractType
} from 'advanced/types.bicep'

// -- Parameters ---------------------------------------------------------------

param location string = resourceGroup().location
param tags object = {}
param resourceToken string

@description('Log Analytics Workspace resource ID for APIM diagnostics')
param logAnalyticsWorkspaceResourceId string

@description('Application Insights instrumentation key')
param appInsightsInstrumentationKey string = ''

@description('Application Insights resource ID')
param appInsightsResourceId string = ''

@description('Foundry instances with per-deployment PTU configuration')
param foundryInstances foundryInstanceType[]

@description('Access contracts defining team identities, priorities, and quotas')
param accessContracts accessContractType[]

@description('APIM SKU tier')
@allowed(['Basicv2', 'Standardv2', 'Premiumv2'])
param apimSku string = 'Basicv2'

@description('Event Hub Namespace name')
param eventHubNamespaceName string = ''

@description('Event Hub name for quota events')
param eventHubName string = ''

// -- Foundry Connection Parameters (optional) ---------------------------------

@description('Foundry account name (for creating per-project connections). Leave empty to skip connections.')
param aiFoundryName string = ''

@description('Project names — each gets its own Foundry connection (identity-based)')
param aiFoundryProjectNames string[] = []

@description('Static model definitions for Foundry model discovery (optional)')
param staticModels ModelType[] = []

// -- Derived ------------------------------------------------------------------

var createFoundryConnections = !empty(aiFoundryName)
var connectionPerProject = createFoundryConnections && !empty(aiFoundryProjectNames)

// Subscriptions are only needed for Foundry connections
var subscriptions = connectionPerProject
  ? map(aiFoundryProjectNames, (projectName) => {
      name: 'sub-${projectName}-${resourceToken}'
      displayName: 'Subscription for ${projectName} in ${aiFoundryName}'
    })
  : createFoundryConnections
      ? [
          {
            name: 'sub-foundry-${aiFoundryName}'
            displayName: 'Default Subscription for ${aiFoundryName}'
          }
        ]
      : []

// ============================================================================
// -- APIM Service (v2 — service only, no inference API)
// ============================================================================
module apimService 'v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceToken
    apimSku: apimSku
    lawId: logAnalyticsWorkspaceResourceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
    apimSubscriptionsConfig: subscriptions
  }
}

// ============================================================================
// -- Per-Model Backend Pools (PTU + Standard)
// ============================================================================
module foundryBackends 'advanced/multi-foundry-backends.bicep' = {
  name: 'foundry-backend-pools'
  dependsOn: [apimService]
  params: {
    apimServiceName: apimService.outputs.name
    foundryInstances: foundryInstances
    configureCircuitBreaker: true
  }
}

// ============================================================================
// -- Contract Config Storage (Blob)
// ============================================================================
module contractStorage 'advanced/contract-storage.bicep' = {
  name: 'contract-storage'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceToken
    contracts: accessContracts
    apimPrincipalId: apimService.outputs.principalId
    ptuCapacityPerModel: foundryBackends.outputs.ptuCapacityPerModel
  }
}

// ============================================================================
// -- Event Hub Logger (for quota-exceeded notifications)
// ============================================================================
var apimName = 'apim-${resourceToken}'
var eventHubEnabled = !empty(eventHubNamespaceName) && !empty(eventHubName)

module eventHubRoleAssignment '../../modules/eventhub/eventhub-role-assignment.bicep' = if (eventHubEnabled) {
  name: 'eventhub-role-assignment'
  params: {
    eventHubNamespaceName: eventHubNamespaceName
    hubName: eventHubName
    principalId: apimService.outputs.principalId
    roleName: 'Azure Event Hubs Data Sender'
  }
}

// https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-log-event-hubs?tabs=bicep
resource eventHubLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = if (eventHubEnabled) {
  parent: apimRef
  name: 'quota-eventhub-logger'
  dependsOn: [apimService, eventHubRoleAssignment]
  properties: {
    loggerType: 'azureEventHub'
    description: 'Event Hub logger for quota-exceeded events (managed identity)'
    credentials: {
      name: eventHubName
      endpointAddress: '${eventHubNamespaceName}.servicebus.windows.net'
      identityClientId: 'systemAssigned'
    }
    isBuffered: false
  }
}

// ============================================================================
// -- APIM Reference
// ============================================================================

resource apimRef 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
  dependsOn: [apimService]
}

// ============================================================================
// -- Policy Fragment: Identity & Authorization
// ============================================================================
var fragmentXml = replace(
  replace(loadTextContent('advanced/fragment-identity.xml'), '{tenant-id}', subscription().tenantId),
  '{contracts-blob-url}',
  contractStorage.outputs.blobUrl
)

resource identityFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  parent: apimRef
  name: 'identity-and-authorization'
  dependsOn: [apimService, contractStorage]
  properties: {
    description: 'Shared JWT validation, identity resolution, contract loading, and model authorization'
    format: 'rawxml'
    value: fragmentXml
  }
}

// ============================================================================
// -- Priority Routing Policy (Main API)
// ============================================================================
var mainPolicyXml = replace(
  replace(loadTextContent('advanced/policy-priority.xml'), '{loopback-backend-id}', 'ptu-gate-loopback'),
  '{eventhub-logger-id}',
  eventHubEnabled ? 'quota-eventhub-logger' : ''
)

// ============================================================================
// -- PTU Gate Policy (Internal Loopback API)
// ============================================================================
var ptuGatePolicyXml = loadTextContent('advanced/policy-ptu-gate.xml')

// ============================================================================
// -- PTU Gate Loopback Backend
// ============================================================================
resource ptuGateLoopbackBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-gate-loopback'
  dependsOn: [apimService, ptuGateApi]
  properties: {
    description: 'Loopback to PTU gate API for atomic PTU token counting via llm-token-limit'
    url: '${apimService.outputs.gatewayUrl}/ptu-gate/openai'
    protocol: 'http'
  }
}

// ============================================================================
// -- PTU Gate API (Internal — called via loopback only)
// ============================================================================
resource ptuGateApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-gate-api'
  dependsOn: [apimService]
  properties: {
    apiType: 'http'
    description: 'Internal PTU gate — applies atomic llm-token-limit before routing to PTU-only backends. Called via loopback from the main inference API.'
    displayName: 'PTU Gate (Internal)'
    path: 'ptu-gate/openai'
    protocols: ['https']
    subscriptionRequired: false
    type: 'http'
  }
}

// Catch-all POST operation (inference requests are always POST)
resource ptuGateCatchAll 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: ptuGateApi
  name: 'catch-all-post'
  properties: {
    displayName: 'Forward POST (catch-all)'
    method: 'POST'
    urlTemplate: '/*'
    description: 'Catches all POST requests for PTU gate processing'
  }
}

resource ptuGatePolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: ptuGateApi
  name: 'policy'
  dependsOn: [foundryBackends]
  properties: {
    format: 'rawxml'
    value: ptuGatePolicyXml
  }
}

// ============================================================================
// -- Inference API (with priority routing policy)
// ============================================================================
// Uses v2/inference-api module for API creation, OpenAPI spec, diagnostics,
// and model discovery — with our priority routing policy.
// Backend pools are created by foundryBackends module (per-model pools),
// so we pass an empty aiServicesConfig to avoid duplicate backend creation.
module inferenceApi 'v2/inference-api.bicep' = {
  name: 'inference-api-deployment'
  dependsOn: [
    foundryBackends
    identityFragment
    ptuGateLoopbackBackend
    contractStorage
    eventHubEnabled ? [eventHubLogger] : null
  ]
  params: {
    policyXml: mainPolicyXml
    apiManagementName: apimService.outputs.name
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'AzureOpenAI'
    inferenceAPIPath: 'inference'
    configureCircuitBreaker: false
    resourceSuffix: resourceToken
    enableModelDiscovery: true
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// ============================================================================
// -- Config Viewer API
// ============================================================================
var configViewerPolicyXml = replace(
  loadTextContent('advanced/policy-config-viewer.xml'),
  '{contracts-blob-url}',
  contractStorage.outputs.blobUrl
)

resource configViewerApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apimRef
  name: 'config-viewer-api'
  dependsOn: [apimService]
  properties: {
    apiType: 'http'
    description: 'Access contract configuration viewer — renders contracts as styled HTML'
    displayName: 'Config Viewer'
    path: 'gateway'
    protocols: ['https']
    subscriptionRequired: false
    type: 'http'
  }
}

resource configViewerOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: configViewerApi
  name: 'get-config'
  properties: {
    displayName: 'View Access Contracts'
    method: 'GET'
    urlTemplate: '/config'
    description: 'Renders all access contracts as a styled HTML page'
  }
}

resource configViewerPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: configViewerOperation
  name: 'policy'
  dependsOn: [contractStorage]
  properties: {
    format: 'rawxml'
    value: configViewerPolicyXml
  }
}

resource configRefreshOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: configViewerApi
  name: 'refresh-config'
  properties: {
    displayName: 'Refresh Contract Cache'
    method: 'POST'
    urlTemplate: '/config/refresh'
    description: 'Clears the cached contracts blob so the next request reloads from storage'
  }
}

resource configRefreshPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: configRefreshOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><cache-remove-value key="contracts-blob-cache" /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"status": "ok", "message": "Contract cache cleared. Next request will reload from blob storage."}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// ============================================================================
// -- Foundry Connections (per-project, identity-based) — optional
// ============================================================================
module aiGatewayProjectConnectionDynamic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connectionPerProject) {
    name: 'apim-connection-dynamic-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-dynamic-for-${projectName}'
      apimResourceId: apimService.outputs.id
      apiName: inferenceApi.outputs.apiName
      apimSubscriptionName: first(filter(
        apimService.outputs.apimSubscriptions,
        (sub) => contains(sub.name, projectName)
      )).name
      isSharedToAll: false
      listModelsEndpoint: '/deployments'
      getModelEndpoint: '/deployments/{deploymentName}'
      deploymentProvider: 'AzureOpenAI'
      inferenceAPIVersion: '2025-03-01-preview'
      authType: 'ProjectManagedIdentity'
    }
  }
]

module aiGatewayProjectConnectionStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connectionPerProject && !empty(staticModels)) {
    name: 'apim-connection-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-static-for-${projectName}'
      apimResourceId: apimService.outputs.id
      apiName: inferenceApi.outputs.apiName
      apimSubscriptionName: first(filter(
        apimService.outputs.apimSubscriptions,
        (sub) => contains(sub.name, projectName)
      )).name
      isSharedToAll: false
      staticModels: staticModels
      inferenceAPIVersion: '2025-03-01-preview'
      authType: 'ProjectManagedIdentity'
    }
  }
]

module aiGatewayConnectionDynamic '../ai/connection-apim-gateway.bicep' = if (createFoundryConnections && !connectionPerProject) {
  name: 'apim-connection-dynamic'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-dynamic'
    apimResourceId: apimService.outputs.id
    apiName: inferenceApi.outputs.apiName
    apimSubscriptionName: first(apimService.outputs.apimSubscriptions).name
    isSharedToAll: true
    listModelsEndpoint: '/deployments'
    getModelEndpoint: '/deployments/{deploymentName}'
    deploymentProvider: 'AzureOpenAI'
    inferenceAPIVersion: '2025-03-01-preview'
    authType: 'ProjectManagedIdentity'
  }
}

// ============================================================================
// -- Outputs
// ============================================================================
output apimResourceId string = apimService.outputs.id
output apimName string = apimService.outputs.name
output apimPrincipalId string = apimService.outputs.principalId
output apimGatewayUrl string = apimService.outputs.gatewayUrl
output inferenceApiUrl string = '${apimService.outputs.gatewayUrl}/${inferenceApi.outputs.apiPath}'
output configViewerUrl string = '${apimService.outputs.gatewayUrl}/gateway/config'
output contractsBlobUrl string = contractStorage.outputs.blobUrl
output contractMapJson string = contractStorage.outputs.contractMapJson
output poolNames array = foundryBackends.outputs.poolNames
output hasPtuDeployments bool = foundryBackends.outputs.hasPtuDeployments
