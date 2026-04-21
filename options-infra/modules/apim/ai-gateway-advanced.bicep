// ============================================================================
// AI Gateway — Advanced (JWT Citadel with Priority Routing)
// ============================================================================
// Extension of the base AI Gateway that adds:
//   - JWT-only auth (no subscription keys) via Entra ID tokens
//   - Per-team access contracts with priority routing (P1 Production / P3 Economy)
//   - Per-model mixed (PTU+PAYG) and PAYG-only backend pools
//   - Circuit breaker on PTU backends for automatic PTU→PAYG failover
//   - Per-model and per-team TPM quotas + monthly cost caps
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

@description('Store contracts in Azure Blob Storage (true) or APIM Named Value (false). Named Value has a 4096-char limit — use Blob Storage for larger contract sets.')
param useStorageAccount bool = true

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
// -- Contract Compilation (shared by both storage modes)
// ============================================================================
// Two structures:
//   1. "contracts": { contractName → config } — the contract definitions
//   2. "identities": [ { prefix, contractName } ] — sorted longest-first for prefix matching
var contractEntries = reduce(
  accessContracts,
  {},
  (cur, contract) =>
    union(cur, {
      '${contract.name}': {
        name: contract.name
        priority: contract.priority
        monthlyQuota: contract.monthlyQuota
        environment: contract.?environment ?? 'UNKNOWN'
        identities: contract.identities
        models: reduce(
          contract.models,
          {},
          (mcur, m) =>
            union(mcur, {
              '${m.name}': {
                tpm: m.tpm
                ptuTpm: m.?ptuTpm ?? 0
              }
            })
        )
      }
    })
)

var identityEntries = flatten(map(
  accessContracts,
  contract =>
    map(contract.identities, id => {
      value: id.value
      claimName: id.claimName
      displayName: id.displayName
      contract: contract.name
    })
))

var contractMap = {
  contracts: contractEntries
  identities: identityEntries
  ptuCapacity: foundryBackends.outputs.ptuCapacityPerModel
}

var contractMapJson = string(contractMap)

// ============================================================================
// -- Contract Config Storage (Blob) — when useStorageAccount is true
// ============================================================================
module contractStorage 'advanced/contract-storage.bicep' = if (useStorageAccount) {
  name: 'contract-storage'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceToken
    contractMapJson: contractMapJson
    apimPrincipalId: apimService.outputs.principalId
  }
}

// ============================================================================
// -- Contract Config Named Value — when useStorageAccount is false
// ============================================================================
module contractNamedValue 'advanced/contract-named-value.bicep' = if (!useStorageAccount) {
  name: 'contract-named-value'
  dependsOn: [apimService]
  params: {
    apimServiceName: apimService.outputs.name
    contractMapJson: contractMapJson
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

// Build the contracts-loading XML block based on storage mode
var contractsBlobUrl = useStorageAccount ? contractStorage.outputs.blobUrl : ''

var contractsLoadBlobTemplate = loadTextContent('advanced/contracts-load-blob.xml')
var contractsLoadBlob = replace(contractsLoadBlobTemplate, '{blob-url}', contractsBlobUrl)

var contractsLoadNamedValue = '<set-variable name="contracts-json" value="{{access-contracts-json}}" />'

var contractsLoadSection = useStorageAccount ? contractsLoadBlob : contractsLoadNamedValue

var fragmentXml = replace(
  replace(loadTextContent('advanced/fragment-identity.xml'), '{tenant-id}', subscription().tenantId),
  '{contracts-load-section}',
  contractsLoadSection
)

resource identityFragment 'Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview' = {
  parent: apimRef
  name: 'identity-and-authorization'
  dependsOn: [apimService, contractStorage, contractNamedValue]
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
  loadTextContent('advanced/policy-priority.xml'),
  '{eventhub-logger-id}',
  eventHubEnabled ? 'quota-eventhub-logger' : ''
)

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
    contractStorage
    contractNamedValue
    ...(eventHubEnabled ? [eventHubLogger] : [])
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

// Build config viewer contracts-loading block (no caching needed for admin page)
var configViewerLoadBlobTemplate = loadTextContent('advanced/contracts-load-blob-nocache.xml')
var configViewerLoadBlob = replace(configViewerLoadBlobTemplate, '{blob-url}', contractsBlobUrl)

var configViewerLoadNamedValue = '<set-variable name="contracts-json" value="{{access-contracts-json}}" />'

var configViewerLoadSection = useStorageAccount ? configViewerLoadBlob : configViewerLoadNamedValue
var contractsSourceLabel = useStorageAccount ? 'Blob Storage &amp;middot; Cached 5 min' : 'APIM Named Value'

var configViewerPolicyXml = replace(
  replace(
    loadTextContent('advanced/policy-config-viewer.xml'),
    '{contracts-load-section}',
    configViewerLoadSection
  ),
  '{contracts-source-label}',
  contractsSourceLabel
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
  dependsOn: [contractStorage, contractNamedValue]
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
    value: useStorageAccount
      ? '<policies><inbound><base /><cache-remove-value key="contracts-blob-cache" /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"status": "ok", "message": "Contract cache cleared. Next request will reload from blob storage."}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
      : '<policies><inbound><base /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"status": "ok", "message": "Contracts are stored as APIM Named Value — no cache to clear. Redeploy to update contracts."}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

resource configJsonOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: configViewerApi
  name: 'get-config-json'
  properties: {
    displayName: 'Get Contracts JSON'
    method: 'GET'
    urlTemplate: '/config.json'
    description: 'Returns all access contracts as raw JSON'
  }
}

resource configJsonPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: configJsonOperation
  name: 'policy'
  dependsOn: [contractStorage, contractNamedValue]
  properties: {
    format: 'rawxml'
    value: useStorageAccount
      ? '<policies><inbound><base />${configViewerLoadBlob}<return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>@((string)context.Variables["contracts-json"])</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
      : '<policies><inbound><base /><return-response><set-status code="200" reason="OK" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{{access-contracts-json}}</set-body></return-response></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
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
output contractsBlobUrl string = useStorageAccount ? contractStorage.outputs.blobUrl : ''
output contractMapJson string = contractMapJson
output poolNames array = foundryBackends.outputs.poolNames
output hasPtuDeployments bool = foundryBackends.outputs.hasPtuDeployments
output useStorageAccount bool = useStorageAccount
