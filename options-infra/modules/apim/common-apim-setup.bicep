import { foundryInstanceType } from 'advanced/types.bicep'
import { ModelType } from '../ai/connection-apim-gateway.bicep'
import { realtimeRouteType } from 'v2/realtime-ws-api.bicep'

param apimName string
param apimLoggerId string
@description('APIM deployment region. Defaults to the resource group location. Used for region-aware PAYG backend prioritization.')
param location string = resourceGroup().location
@allowed([
  'Consumption'
  'Developer'
  'Basic'
  'Basicv2'
  'Standard'
  'StandardV2'
  'Standardv2'
  'Premium'
  'Premiumv2'
])
@description('Apim SKU - used to determine if full OpenAI spec can be deployed (requires Standardv2 or Premium)')
param apimSku string = 'Basicv2'

@allowed(['ApiKey', 'ProjectManagedIdentity'])
param gatewayAuthenticationType string = 'ProjectManagedIdentity'

@description('Tenant IDs whose Entra ID tokens are accepted as inbound auth. When non-empty, both inference APIs inject a `<validate-jwt>` block that requires `aud=https://cognitiveservices.azure.com` and lists one issuer per tenant (both v1 `sts.windows.net/{tid}/` and v2 `login.microsoftonline.com/{tid}/v2.0`). Empty (default) = no inbound JWT validation — backward-compatible with ApiKey / anonymous callers.')
param acceptedTenantIds string[] = []

@description('Existing Foundry/AI Services instances to register as backends.')
param foundryInstances foundryInstanceType[]

@description('When true, create a dedicated {model}-ptu-pool for every model with at least one PTU backend and route priority==1 callers there. When false (default), all backends (PTU + PAYG) live in a single {model}-pool with PTU at low priority (200) acting as overflow capacity.')
param priorityRouting bool = false

@description('Application Insights instrumentation key for logging.')
param appInsightsInstrumentationKey string = ''
@description('Application Insights resource ID for logging.')
param appInsightsResourceId string = ''

// -- Constants ----------------------------------------------------------------
// Passthrough API resource name. Must match what we pass to the v2 module
// below so the discovery operations (added via `existing` references) can find
// it deterministically.
var passthroughApiName = 'inference-api'

@description('URL path for the spec-backed AzureOpenAI API. Must not collide with the passthrough path (`inference/openai`). The AzureOpenAI inference-api module appends `/openai`, so a value of `openai` exposes the API at `…/openai/openai/…` — use `azure` (default) for `…/azure/openai/…`.')
var specApiPath string = 'azure'

// -- Multi-tenant inbound JWT validation -------------------------------------
// Replaces the `{JWT_VALIDATION}` token in policy-per-model.xml.
//   acceptedTenantIds empty (default) → emit an XML comment (no validation);
//     preserves backward compatibility for ApiKey / anonymous samples.
//   acceptedTenantIds non-empty      → emit a full <validate-jwt> block that
//     accepts BOTH v1 (`sts.windows.net`) and v2 (`login.microsoftonline.com/.../v2.0`)
//     issuers since AAD tokens may carry either depending on how the caller
//     acquired them.
var issuersXml = join(map(acceptedTenantIds, tid => '<issuer>https://sts.windows.net/${tid}/</issuer>\n<issuer>https://login.microsoftonline.com/${tid}/v2.0</issuer>'), '')
var jwtValidationXml = empty(acceptedTenantIds)
  ? '<!-- inbound JWT validation disabled (acceptedTenantIds is empty) -->'
  : '<validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized"><openid-config url="https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" /><audiences><audience>https://cognitiveservices.azure.com</audience><audience>https://cognitiveservices.azure.com/</audience></audiences><issuers>${issuersXml}</issuers></validate-jwt>'

var policyPerModelXml = replace(loadTextContent('policy-per-model.xml'), '{JWT_VALIDATION}', jwtValidationXml)

// Union of all deployments across all instances → ModelType[] for the Foundry
// connection's portal model picker. Dedupes by modelName (first wins when
// multiple instances serve the same model). modelVersion/modelFormat are
// captured by the discovery script from `properties.model.{version,format}`
// on the backing deployment; fall back to AzureOpenAI defaults only when the
// script ran against an older schema that didn't capture them.
var allDeployments = flatten(map(foundryInstances, inst => inst.deployments))
var dedupedDeployments = reduce(
  allDeployments,
  [],
  (acc, d) => contains(map(acc, x => x.modelName), d.modelName) ? acc : concat(acc, [d])
)
var staticModels ModelType[] = [
  for d in dedupedDeployments: {
    name: d.modelName
    properties: {
      model: {
        name: d.modelName
        version: d.?modelVersion ?? '2025-01-01-preview'
        format: d.?modelFormat ?? 'OpenAI'
      }
    }
  }
]

// -- Realtime (WebSocket) routes ---------------------------------------------
// Realtime deployments need a dedicated WebSocket API — HTTP per-model pools
// can't carry a wss handshake. Build one route per (instance, realtime
// deployment) mapping the deployment name to a concrete APIM backend and its
// backing instance's wss base URL. Match on model-name criterion
// (gpt-* + realtime) while also honoring the captured Realtime model format.
var realtimeRoutes realtimeRouteType[] = flatten(map(
  foundryInstances,
  inst => map(
    filter(inst.deployments, d => toLower(d.?modelFormat ?? '') == 'realtime' || (startsWith(toLower(d.modelName), 'gpt-') && contains(toLower(d.modelName), 'realtime'))),
    d => {
      deploymentName: d.modelName
      endpoint: '${replace(inst.endpoint, 'https:', 'wss:')}${endsWith(inst.endpoint, '/') ? '' : '/'}openai/realtime'
    }
  )
))
var hasRealtime = !empty(realtimeRoutes)

// ============================================================================
// -- Policy fragments (shared by inbound policies of every inference API)
// ============================================================================
module callerIdentityFragment 'caller-identity-fragment.bicep' = {
  name: 'caller-identity-fragment'
  params: {
    apiManagementName: apimName
  }
}

module perModelRoutingFragment 'per-model-routing-fragment.bicep' = {
  name: 'per-model-routing-fragment'
  params: {
    apiManagementName: apimName
    foundryInstances: foundryInstances
    priorityRouting: priorityRouting
  }
}

// ============================================================================
// -- Per-model backends + per-model pools
// ============================================================================
// foundryInstances is honored as-is — instances flagged isPtu=true contribute
// PTU backends. Pool topology depends on `priorityRouting`:
//   false (default): single {model}-pool per model contains every backend
//                    (PAYG pri 50/100, PTU pri 200 overflow). One pool.
//   true:            {model}-pool is PAYG-only; {model}-ptu-pool (when at
//                    least one PTU backend) contains PTU pri 1 + PAYG pri
//                    50/100 fallback. priority==1 callers hit ptu-pool.
// Circuit breaker isolates throttled (instance, model) pairs so APIM falls
// through to the next backend in the pool.
module foundryBackends 'advanced/multi-foundry-backends.bicep' = {
  name: 'foundry-backend-pools'
  params: {
    apimServiceName: apimName
    apimLocation: location
    foundryInstances: foundryInstances
    configureCircuitBreaker: true
    priorityRouting: priorityRouting
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
// API path is `inference`; the inbound `/openai/...` or `/anthropic/...`
// segment is carried through to the backend so a single API surfaces both
// AzureOpenAI (`/inference/openai/deployments/{m}/...`) and Anthropic
// (`/inference/anthropic/v1/messages`) shapes — backwards compatible with
// the legacy `…/inference/openai/...` URL contract.
module inferenceApi 'v2/inference-api.bicep' = {
  name: 'inference-api-deployment'
  dependsOn: [foundryBackends, callerIdentityFragment, perModelRoutingFragment]
  params: {
    policyXml: policyPerModelXml
    apiManagementName: apimName
    apimLoggerId: apimLoggerId
    aiServicesConfig: []
    inferenceAPIType: 'Other'
    inferenceAPIPath: 'inference'
    inferenceAPIName: passthroughApiName
    configureCircuitBreaker: false
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
module inferenceApiSpec 'v2/inference-api-azure.bicep' = {
  name: 'inference-api-spec-deployment'
  dependsOn: [inferenceApi, callerIdentityFragment, perModelRoutingFragment]
  params: {
    policyXml: policyPerModelXml
    apiManagementName: apimName
    apimLoggerId: apimLoggerId
    inferenceAPIPath: specApiPath
    inferenceAPIName: 'inference-api-azure'
    inferenceAPIDisplayName: 'Inference API (Azure OpenAI spec)'
    inferenceAPIDescription: 'AzureOpenAI-spec inference API — same per-model routing as the passthrough, with portal test console and per-operation definitions.'
    requireSubscriptionKey: gatewayAuthenticationType != 'ProjectManagedIdentity'
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// ============================================================================
// -- Realtime (WebSocket) API — only when realtime deployments exist
// ============================================================================
// Dedicated wss API at `inference/openai/realtime`. WebSocket APIs can't use
// backend pools, so the onHandshake policy routes per-deployment to a concrete
// wss backend (advanced/multi-foundry-backends is bypassed here). Reuses the
// same inbound JWT validation as the HTTP APIs. Depends on inferenceApi to
// avoid the service-level `inference` tag race condition.
module realtimeApi 'v2/realtime-ws-api.bicep' = if (hasRealtime) {
  name: 'realtime-ws-api-deployment'
  dependsOn: [inferenceApi]
  params: {
    apiManagementName: apimName
    apimLoggerId: apimLoggerId
    inferenceAPIPath: 'inference'
    realtimeRoutes: realtimeRoutes
    jwtValidationXml: jwtValidationXml
    requireSubscriptionKey: gatewayAuthenticationType != 'ProjectManagedIdentity'
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
  }
}

// OpenAI v1 API has more than 100 Operations and requires Premium, Premiumv2, or StandardV2 SKU
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits?toc=%2Fazure%2Fapi-management%2Ftoc.json&bc=%2Fazure%2Fapi-management%2Fbreadcrumb%2Ftoc.json#limits---api-management-v2-tiers
// Depends on inference_api to avoid race condition creating duplicate APIM service-level tags
module openaiV1Api 'v2/openai-api-v1.bicep' = if (contains(['Premium', 'StandardV2', 'Premiumv2'], apimSku)) {
  name: 'openai-v1-api-deployment'
  dependsOn: [inferenceApi]
  params: {
    policyXml: policyPerModelXml
    apiManagementName: apimName
    apimLoggerId: apimLoggerId
    inferenceAPIPath: 'openai/v1'
    inferenceAPIDescription: 'OpenAI API v1 for AI Gateway'
    inferenceAPIDisplayName: 'OpenAI API v1'
    inferenceAPIName: 'openai-api-v1'
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

var listDeploymentsPolicyXml = replace(
  replace(
    loadTextContent('policy-list-deployments.xml'),
    '{DEPLOYMENTS_LIST_JSON}',
    deploymentsListJsonEncoded
  ),
  '{JWT_VALIDATION}',
  jwtValidationXml
)
var getDeploymentPolicyXml = replace(
  replace(
    loadTextContent('policy-get-deployment.xml'),
    '{DEPLOYMENTS_LIST_JSON}',
    deploymentsListJsonEncoded
  ),
  '{JWT_VALIDATION}',
  jwtValidationXml
)

module passthroughDiscovery 'static-discovery-operations.bicep' = {
  name: 'passthrough-discovery-ops'
  dependsOn: [inferenceApi]
  params: {
    apimServiceName: apimName
    apiName: passthroughApiName
    listDeploymentsPolicyXml: listDeploymentsPolicyXml
    getDeploymentPolicyXml: getDeploymentPolicyXml
    resourceSuffix: 'passthrough'
  }
}

module specApiDiscovery 'static-discovery-operations.bicep' = {
  name: 'spec-api-discovery-ops'
  dependsOn: [inferenceApiSpec]
  params: {
    apimServiceName: apimName
    apiName: 'inference-api-azure'
    listDeploymentsPolicyXml: listDeploymentsPolicyXml
    getDeploymentPolicyXml: getDeploymentPolicyXml
    resourceSuffix: 'spec'
  }
}

output backendNames array = foundryBackends.outputs.backendNames
output poolNames array = foundryBackends.outputs.poolNames
output inferenceApiName string = passthroughApiName
output staticModels ModelType[] = staticModels
output hasRealtime bool = hasRealtime
output realtimeApiPath string = hasRealtime ? realtimeApi!.outputs.apiPath : ''
