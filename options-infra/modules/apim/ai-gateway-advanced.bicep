// ============================================================================
// AI Gateway — Advanced (JWT Citadel with Priority Routing)
// ============================================================================
// Extension of the base AI Gateway that adds:
//   - JWT-only auth (no subscription keys) via Entra ID tokens
//   - Per-team access contracts with priority routing (P1/P2/P3)
//   - Per-model backend pools with PTU/standard separation
//   - Per-model and per-team TPM quotas + monthly cost caps
//   - PTU utilization-aware routing for P2 traffic
//   - Per-project Foundry connections (identity-based, optional)
//   - PTU simulator for testing without real PTU deployments
//
// Uses: v2/apim.bicep (APIM service), v2/inference-api.bicep (inference API)
// Adds: advanced/contract-storage, advanced/multi-foundry-backends, priority policy
// ============================================================================

import { ModelType } from '../ai/connection-apim-gateway.bicep'
import {
  foundryInstanceType
  accessContractType
  ptuSimulatorConfigType
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

@description('PTU simulator configuration for testing without real PTU')
param ptuSimulator ptuSimulatorConfigType = {
  enabled: false
}

@description('P2 routing threshold — route to PTU when utilization < this value (0.0–1.0)')
param ptuUtilizationThreshold string = '0.7'

@description('APIM SKU tier')
@allowed(['Basicv2', 'Standardv2', 'Premiumv2'])
param apimSku string = 'Basicv2'

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
      ? [{
          name: 'sub-foundry-${aiFoundryName}'
          displayName: 'Default Subscription for ${aiFoundryName}'
        }]
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
// -- APIM Named Values (PTU config)
// ============================================================================
var apimName = 'apim-${resourceToken}'

resource apimRef 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

resource ptuThresholdNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-utilization-threshold'
  dependsOn: [apimService]
  properties: {
    displayName: 'ptu-utilization-threshold'
    value: ptuUtilizationThreshold
    secret: false
    tags: ['routing', 'ptu']
  }
}

resource ptuSimulatorEnabledNv 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-simulator-enabled'
  dependsOn: [apimService]
  properties: {
    displayName: 'ptu-simulator-enabled'
    value: ptuSimulator.enabled ? 'true' : 'false'
    secret: false
    tags: ['simulator', 'ptu']
  }
}

resource ptuSimulatorCapacityNv 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-simulator-capacity'
  dependsOn: [apimService]
  properties: {
    displayName: 'ptu-simulator-capacity'
    value: string(ptuSimulator.?simulatedCapacityTpm ?? 100000)
    secret: false
    tags: ['simulator', 'ptu']
  }
}

resource ptuSimulatorUtilizationNv 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apimRef
  name: 'ptu-simulator-base-utilization'
  dependsOn: [apimService]
  properties: {
    displayName: 'ptu-simulator-base-utilization'
    value: ptuSimulator.?simulatedUtilization ?? '0.3'
    secret: false
    tags: ['simulator', 'ptu']
  }
}

// ============================================================================
// -- Priority Routing Policy
// ============================================================================
var ptuSimulatorFragment = ptuSimulator.enabled
  ? loadTextContent('advanced/ptu-simulator-fragment.xml')
  : '<!-- PTU simulator disabled -->'

var policyXml = replace(
  replace(
    replace(
      loadTextContent('advanced/policy-priority.xml'),
      '{tenant-id}',
      subscription().tenantId
    ),
    '{contracts-blob-url}',
    contractStorage.outputs.blobUrl
  ),
  '{ptu-simulator-fragment}',
  ptuSimulatorFragment
)

var finalPolicyXml = replace(
  policyXml,
  '{ptu-utilization-threshold}',
  '{{ptu-utilization-threshold}}'
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
    ptuThresholdNamedValue
    ptuSimulatorEnabledNv
    ptuSimulatorCapacityNv
    ptuSimulatorUtilizationNv
    contractStorage
  ]
  params: {
    policyXml: finalPolicyXml
    apiManagementName: apimService.outputs.name
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'AzureOpenAI'
    inferenceAPIPath: 'inference/openai'
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
      apimSubscriptionName: first(filter(apimService.outputs.apimSubscriptions, (sub) => contains(sub.name, projectName))).name
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
      apimSubscriptionName: first(filter(apimService.outputs.apimSubscriptions, (sub) => contains(sub.name, projectName))).name
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
