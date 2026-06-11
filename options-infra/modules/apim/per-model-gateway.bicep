// ============================================================================
// AI Gateway — Per-Model Routing (no quota / no JWT)
// ============================================================================
// Lightweight sibling of ai-gateway-advanced.bicep for the "basic" sample:
//   • One APIM backend per (foundry instance, model) — circuit-breaker scoped
//     to a single model so a throttled deployment can't disable others.
//   • Per-model PAYG pool — pool name = `{model-clean}-payg-pool`.
//   • Inbound policy extracts the model from the URL and sets the backend.
//   • No JWT validation, no access contracts, no quota. Add ai-gateway-advanced
//     if you need those.
//
// Composes: v2/apim.bicep, v2/inference-api.bicep, advanced/multi-foundry-backends.bicep,
// caller-identity-fragment.bicep, ai/connection-apim-gateway.bicep.
// ============================================================================

import { foundryInstanceType } from 'advanced/types.bicep'
import { ModelType } from '../ai/connection-apim-gateway.bicep'
import { subscriptionType } from 'v2/apim.bicep'

// -- Parameters ---------------------------------------------------------------
param location string = resourceGroup().location
param tags object = {}
param resourceToken string

@description('Existing Foundry/AI Services instances to register as backends.')
param foundryInstances foundryInstanceType[]

@description('Foundry account name — used to create Foundry-side connections to the gateway.')
param aiFoundryName string

@description('Project names — each gets its own per-project Foundry connection.')
param aiFoundryProjectNames string[] = []

@description('Static model list registered on the Foundry connection (drives the portal model picker).')
param staticModels ModelType[] = []

@allowed(['ApiKey', 'ProjectManagedIdentity'])
param gatewayAuthenticationType string = 'ProjectManagedIdentity'

@description('APIM SKU.')
@allowed(['Basicv2', 'Standardv2', 'Premiumv2'])
param apimSku string = 'Basicv2'

@description('Also deploy a spec-backed AzureOpenAI inference API (with per-operation definitions, model-discovery endpoints, and the APIM test console) alongside the Foundry-facing passthrough. Both APIs share the same per-model routing fragment, so they hit the same backend pools.')
param deploySpecApi bool = true

@description('URL path for the spec-backed AzureOpenAI API. Must not collide with the passthrough path (`inference/openai`). The AzureOpenAI inference-api module appends `/openai`, so a value of `openai` exposes the API at `…/openai/openai/…` — use `azure` (default) for `…/azure/openai/…`.')
param specApiPath string = 'azure'

param logAnalyticsWorkspaceResourceId string
param appInsightsInstrumentationKey string = ''
param appInsightsResourceId string = ''

// -- Constants ----------------------------------------------------------------
// Passthrough API resource name. Must match what we pass to the v2 module
// below so the discovery operations (added via `existing` references) can find
// it deterministically.
var passthroughApiName = 'inference-api'

// -- Derived ------------------------------------------------------------------
var connectionPerProject = !empty(aiFoundryProjectNames)
var subscriptions subscriptionType[] = connectionPerProject
  ? map(aiFoundryProjectNames, (projectName) => {
      name: 'sub-${projectName}-${resourceToken}'
      displayName: 'Subscription for ${projectName} in ${aiFoundryName}'
    })
  : [
      {
        name: 'sub-foundry-${aiFoundryName}'
        displayName: 'Default Subscription for ${aiFoundryName}'
      }
    ]

// ============================================================================
// -- APIM service
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
// -- Policy fragments (shared by inbound policies of every inference API)
// ============================================================================
module callerIdentityFragment 'caller-identity-fragment.bicep' = {
  name: 'caller-identity-fragment'
  params: {
    apiManagementName: apimService.outputs.name
  }
}

module perModelRoutingFragment 'per-model-routing-fragment.bicep' = {
  name: 'per-model-routing-fragment'
  params: {
    apiManagementName: apimService.outputs.name
  }
}

// ============================================================================
// -- Per-model backends + per-model PAYG pools
// ============================================================================
// All instances are treated as PAYG (isPtu=false) — PTU routing belongs in the
// advanced gateway. Circuit breaker is still useful: it isolates a throttled
// (instance, model) pair so APIM falls through to the next backend in the pool.
module foundryBackends 'advanced/multi-foundry-backends.bicep' = {
  name: 'foundry-backend-pools'
  params: {
    apimServiceName: apimService.outputs.name
    foundryInstances: foundryInstances
    configureCircuitBreaker: true
  }
}

// ============================================================================
// -- Inference API #1 — Foundry-facing passthrough (catch-all, no operations)
// ============================================================================
// aiServicesConfig is empty: backends + pools are owned by `foundryBackends`,
// the policy fragment sets `set-backend-service` per request based on the
// requested model name.
//
// inferenceAPIType='Other' loads the PassThrough OpenAPI spec (single `/*`
// path with all 8 HTTP verbs) — Foundry / clients hit the API transparently
// and our policy routes to the per-model pool based on the URL segment.
// We force inferenceAPIPath='inference/openai' so the external URL contract
// stays `…/inference/openai/deployments/{model}/...` for AzureOpenAI SDK
// callers and for our policy's URL-segment parsing.
module inferenceApi 'v2/inference-api.bicep' = {
  name: 'inference-api-deployment'
  dependsOn: [foundryBackends, callerIdentityFragment, perModelRoutingFragment]
  params: {
    policyXml: loadTextContent('policy-per-model.xml')
    apiManagementName: apimService.outputs.name
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'Other'
    inferenceAPIPath: 'inference/openai'
    inferenceAPIName: passthroughApiName
    configureCircuitBreaker: false
    resourceSuffix: resourceToken
    enableModelDiscovery: false
    requireSubscriptionKey: gatewayAuthenticationType != 'ProjectManagedIdentity'
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// ============================================================================
// -- Inference API #2 — Spec-backed AzureOpenAI (test console + per-op def)
// ============================================================================
// Same per-model routing as the passthrough (shares the routing fragment), but
// uses the AzureOpenAI OpenAPI spec so the APIM portal renders the test
// console and SDK generators see per-operation definitions.
// `dependsOn: [inferenceApi]` avoids the service-level `inference` tag race
// condition between concurrent API deployments.
module inferenceApiSpec 'v2/inference-api.bicep' = if (deploySpecApi) {
  name: 'inference-api-spec-deployment'
  dependsOn: [inferenceApi, foundryBackends, callerIdentityFragment, perModelRoutingFragment]
  params: {
    policyXml: loadTextContent('policy-per-model.xml')
    apiManagementName: apimService.outputs.name
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'AzureOpenAI'
    inferenceAPIPath: specApiPath
    inferenceAPIName: 'inference-api-azure'
    inferenceAPIDisplayName: 'Inference API (Azure OpenAI spec)'
    inferenceAPIDescription: 'AzureOpenAI-spec inference API — same per-model routing as the passthrough, with portal test console and per-operation definitions.'
    configureCircuitBreaker: false
    resourceSuffix: resourceToken
    enableModelDiscovery: false
    requireSubscriptionKey: gatewayAuthenticationType != 'ProjectManagedIdentity'
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// ============================================================================
// -- Discovery operations (`GET /deployments` + `…/{name}`)
// ============================================================================
// Returns the static list captured from `staticModels` at IaC deploy time —
// no upstream call. Replaces the legacy ARM-proxy implementation that called
// `Microsoft.CognitiveServices/accounts/deployments` at request time (which
// only worked against a single instance and silently broke as soon as the
// gateway fronted multiple Foundries).
//
// Attached to BOTH inference APIs so callers get an authoritative deduped
// view regardless of which surface they use.

// ARM `accounts/deployments` list response shape. Same blob is used by both
// the list and the get-by-name policies — the get-by-name policy does an
// in-memory lookup against this JSON.
//
// XML-encode `&`, `<`, `>`, `"` so the JSON survives intact whether it lands
// inside an XML element body (`<set-body>…</set-body>`) or an attribute value
// (`<set-variable value="…" />`). APIM decodes entity refs before passing the
// string to the policy engine, so context.Variables[…] sees the original JSON.
// Order matters: encode `&` first, otherwise it would clobber the others.
var rawDeploymentsListJson = string({ value: staticModels })
var deploymentsListJsonEncoded = replace(replace(replace(replace(rawDeploymentsListJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')

var listDeploymentsPolicyXml = replace(loadTextContent('policy-list-deployments.xml'), '{DEPLOYMENTS_LIST_JSON}', deploymentsListJsonEncoded)
var getDeploymentPolicyXml = replace(loadTextContent('policy-get-deployment.xml'), '{DEPLOYMENTS_LIST_JSON}', deploymentsListJsonEncoded)

module passthroughDiscovery 'static-discovery-operations.bicep' = {
  name: 'passthrough-discovery-ops'
  dependsOn: [inferenceApi]
  params: {
    apimServiceName: apimService.outputs.name
    apiName: passthroughApiName
    listDeploymentsPolicyXml: listDeploymentsPolicyXml
    getDeploymentPolicyXml: getDeploymentPolicyXml
    resourceSuffix: 'passthrough'
  }
}

module specApiDiscovery 'static-discovery-operations.bicep' = if (deploySpecApi) {
  name: 'spec-api-discovery-ops'
  dependsOn: [inferenceApiSpec]
  params: {
    apimServiceName: apimService.outputs.name
    apiName: 'inference-api-azure'
    listDeploymentsPolicyXml: listDeploymentsPolicyXml
    getDeploymentPolicyXml: getDeploymentPolicyXml
    resourceSuffix: 'spec'
  }
}

// ============================================================================
// -- Foundry connection(s) — static models drive the portal model picker
// ============================================================================
module aiGatewayConnectionStatic '../ai/connection-apim-gateway.bicep' = if (!connectionPerProject && !empty(staticModels)) {
  name: 'apim-connection-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-static'
    apimResourceId: apimService.outputs.id
    apiName: inferenceApi.outputs.apiName
    apimSubscriptionName: first(apimService.outputs.apimSubscriptions).name
    isSharedToAll: true
    staticModels: staticModels
    inferenceAPIVersion: '2025-03-01-preview'
    authType: gatewayAuthenticationType
  }
}

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
      authType: gatewayAuthenticationType
    }
  }
]

// -- Outputs ------------------------------------------------------------------
output apimResourceId string = apimService.outputs.id
output apimName string = apimService.outputs.name
output apimPrincipalId string = apimService.outputs.principalId
output apimGatewayUrl string = apimService.outputs.gatewayUrl
output backendNames array = foundryBackends.outputs.backendNames
output poolNames array = foundryBackends.outputs.poolNames
