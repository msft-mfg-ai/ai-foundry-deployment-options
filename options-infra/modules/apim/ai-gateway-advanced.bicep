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
// Adds: advanced/contract-storage, advanced/multi-foundry-backends, shared fragments/policies
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

@description('Store contracts in Azure Blob Storage. Advanced config update endpoints require blob storage; false is no longer supported by this orchestrator.')
param useStorageAccount bool = true

@description('Tenant IDs whose Entra ID tokens are accepted as inbound auth. Defaults to the current subscription tenant. The first tenant is also used by the access-contract caller fragment.')
param acceptedTenantIds string[] = []

// -- Foundry Connection Parameters (optional) ---------------------------------

@description('Foundry account name (for creating per-project connections). Leave empty to skip connections.')
param aiFoundryName string = ''

@description('Project names — each gets its own Foundry connection (identity-based)')
param aiFoundryProjectNames string[] = []

@description('Static model definitions for Foundry model discovery (optional)')
param staticModels ModelType[] = []

@description('When true, create a dedicated {model}-ptu-pool per model with PTU backends and route priority==1 callers there. When false (default), all backends live in a single {model}-pool with PTU at priority 200 (overflow).')
param priorityRouting bool = false

// -- Derived ------------------------------------------------------------------

var apiManagementName = 'apim-ai-${resourceToken}'
var createFoundryConnections = !empty(aiFoundryName)
var connectionPerProject = createFoundryConnections && !empty(aiFoundryProjectNames)
var validStorageMode = useStorageAccount ? true : fail('ai-gateway-advanced.bicep now requires useStorageAccount=true because advanced config endpoints read and update the contracts blob.')
var effectiveAcceptedTenantIds = empty(acceptedTenantIds) ? [tenant().tenantId] : acceptedTenantIds
var acceptedTenantId = first(effectiveAcceptedTenantIds)

// Replaces the `{JWT_VALIDATION}` token in policy-per-model.xml. Each accepted
// tenant contributes BOTH the v1 (`sts.windows.net`) and v2
// (`login.microsoftonline.com/.../v2.0`) issuer URLs since Entra tokens can
// carry either depending on how the caller acquired them.
var issuersXml = join(
  map(
    effectiveAcceptedTenantIds,
    tid => '<issuer>https://sts.windows.net/${tid}/</issuer>\n<issuer>https://login.microsoftonline.com/${tid}/v2.0</issuer>'
  ),
  ''
)
#disable-next-line no-hardcoded-env-urls
var jwtValidationXml = '<validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized"><openid-config url="https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" /><audiences><audience>https://cognitiveservices.azure.com</audience><audience>https://cognitiveservices.azure.com/</audience></audiences><issuers>${issuersXml}</issuers></validate-jwt>'
var policyPerModelXml = replace(loadTextContent('policy-per-model.xml'), '{JWT_VALIDATION}', jwtValidationXml)

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
    apiManagementName: apiManagementName
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
    apimServiceName: apiManagementName
    apimLocation: location
    foundryInstances: foundryInstances
    configureCircuitBreaker: true
    priorityRouting: priorityRouting
  }
}

// ============================================================================
// -- Contract Compilation (stored in Blob)
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
module contractStorage 'advanced/contract-storage.bicep' = if (validStorageMode) {
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
// -- Event Hub Logger (for quota-exceeded notifications)
// ============================================================================
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
  name: apiManagementName
}

// ============================================================================
// -- Shared Policy Fragments
// ============================================================================

module callerIdentityFragment 'caller-identity-fragment.bicep' = {
  name: 'caller-identity-fragment'
  params: {
    apiManagementName: apiManagementName
    contractsBlobUrl: contractStorage.outputs.blobUrl
    acceptedTenantId: acceptedTenantId
  }
}

module perModelRoutingFragment 'per-model-routing-fragment.bicep' = {
  name: 'per-model-routing-fragment'
  params: {
    apiManagementName: apiManagementName
    foundryInstances: foundryInstances
    priorityRouting: priorityRouting
  }
}

// ============================================================================
// -- Inference API (with shared per-model policy)
// ============================================================================
// Uses v2/inference-api module for API creation, OpenAPI spec, diagnostics,
// and model discovery. Backend pools are created by foundryBackends module
// (per-model pools), so we pass an empty aiServicesConfig to avoid duplicate
// backend creation.
module inferenceApi 'v2/inference-api.bicep' = {
  name: 'inference-api-deployment'
  dependsOn: [
    foundryBackends
    callerIdentityFragment
    perModelRoutingFragment
    ...(eventHubEnabled ? [eventHubLogger] : [])
  ]
  params: {
    policyXml: policyPerModelXml
    apiManagementName: apiManagementName
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'AzureOpenAI'
    inferenceAPIPath: 'inference'
    requireSubscriptionKey: false
    configureCircuitBreaker: false
    enableModelDiscovery: true
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// ============================================================================
// -- Advanced Config Operations
// ============================================================================

module advancedPolicies 'advanced/advanced-policies.bicep' = {
  name: 'advanced-policies'
  dependsOn: [inferenceApi]
  params: {
    apimServiceName: apiManagementName
    apiName: inferenceApi.outputs.apiName
    contractsBlobUrl: contractStorage.outputs.blobUrl
    storageAccountName: contractStorage.outputs.storageAccountName
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
output configViewerUrl string = '${apimService.outputs.gatewayUrl}/${inferenceApi.outputs.apiPath}/ai-gateway/config.json'
output contractsBlobUrl string = contractStorage.outputs.blobUrl
output contractMapJson string = contractMapJson
output poolNames array = foundryBackends.outputs.poolNames
output hasPtuDeployments bool = foundryBackends.outputs.hasPtuDeployments
output useStorageAccount bool = useStorageAccount
