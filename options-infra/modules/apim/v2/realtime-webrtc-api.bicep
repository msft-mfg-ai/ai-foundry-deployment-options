/**
 * @module realtime-webrtc-api
 * @description Creates a dedicated HTTP API in APIM that fronts the Azure
 * OpenAI **Realtime WebRTC** contract (GA `/openai/v1/realtime/*` surface).
 *
 * Two operations are exposed:
 *   POST /calls             — SDP exchange; caller supplies an *ephemeral*
 *                             Bearer token (issued from /client_secrets).
 *                             Foundry rejects any AAD/MI token here.
 *   POST /client_secrets    — mint an ephemeral token; caller supplies an
 *                             *AAD/MI* Bearer token. Optional inbound JWT
 *                             validation is applied here (never on /calls).
 *
 * This lives on a dedicated API — separate from `openai-api-v1` — because the
 * general per-model policy uses `set-backend-service backend-id="<pool>"`
 * against a Backend resource that has managed-identity credentials attached.
 * APIM auto-injects that MI Authorization AFTER policy runs, overwriting the
 * caller's ephemeral token, which Foundry then rejects with
 *   "Realtime session ephemeral token is invalid".
 * Here we use `set-backend-service base-url="…"` (no attached credentials) so
 * the caller Authorization flows through unmodified. See
 * ../realtime-webrtc-policy.xml.
 *
 * The API is exposed at `openai-v1/realtime` — a strictly longer path prefix
 * than the `openai-v1` catch-all, so APIM's longest-prefix API selection
 * routes `/openai-v1/realtime/*` here and all other `/openai-v1/*` traffic to
 * the general OpenAI v1 API.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the API Management instance.')
param apiManagementName string

@description('Id of the APIM Logger for Azure Monitor diagnostics. Empty disables the azuremonitor diagnostic.')
param apimLoggerId string = ''

@description('Base path of the OpenAI v1 API surface (without leading/trailing slash). The realtime API is created at `{inferenceAPIPath}/realtime`.')
param inferenceAPIPath string = 'openai-v1'

@description('Realtime deployment routes. One entry per realtime model deployment, mapping the deployment name to the backing instance https base URL (without trailing slash), e.g. `https://acct.cognitiveservices.azure.com/openai/v1/realtime`.')
param realtimeRoutes realtimeWebrtcRouteType[]

@description('Pre-rendered `<validate-jwt>` block injected into the /client_secrets branch. Empty string disables inbound caller-token validation.')
param jwtValidationXml string = ''

@description('Whether to require an APIM subscription key on this API. Under ProjectManagedIdentity auth this is false (the JWT policy gates /client_secrets, ephemeral gates /calls).')
param requireSubscriptionKey bool = false

@description('The instrumentation key for Application Insights.')
@secure()
param appInsightsInstrumentationKey string = ''

@description('The resource ID for Application Insights.')
param appInsightsId string = ''

// ------------------
//    TYPE DEFINITIONS
// ------------------

@export()
@description('A single realtime WebRTC route: deployment/model name → backing instance https base URL that ends in `/openai/v1/realtime`.')
type realtimeWebrtcRouteType = {
  @description('Deployment/model name as used in the realtime URL query (e.g. "gpt-realtime-2").')
  deploymentName: string

  @description('Backing instance https base URL, e.g. "https://acct.cognitiveservices.azure.com/openai/v1/realtime". APIM appends the operation suffix (`/calls` or `/client_secrets`) and the caller query string.')
  endpoint: string
}

// ------------------
//    VARIABLES
// ------------------

import { requestLogSettings } from '../log-settings.bicep'
var logSettings = requestLogSettings

// Dedupe by deployment name (first route wins) — multiple instances serving
// the same realtime deployment collapse to one entry (WebRTC media is
// peer-to-peer so per-connection load-balancing has no value).
var dedupedRoutes = reduce(
  realtimeRoutes,
  [],
  (acc, r) => contains(map(acc, x => x.deploymentName), r.deploymentName) ? acc : concat(acc, [r])
)
var routingMapObject = reduce(
  dedupedRoutes,
  {},
  (acc, r) => union(acc, { '${r.deploymentName}': r.endpoint })
)
var routingMapJson = string(routingMapObject)

// XML-encode the JSON so it survives intact inside the policy attribute value.
// APIM decodes entity refs before the policy engine sees the string.
var routingMapEncoded = replace(
  replace(replace(replace(routingMapJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
  '"',
  '&quot;'
)

var apiPolicyXml = replace(
  replace(loadTextContent('../realtime-webrtc-policy.xml'), '{ROUTING_MAP}', routingMapEncoded),
  '{JWT_VALIDATION}',
  jwtValidationXml
)

// Default serviceUrl — the policy overrides it per request, but a valid https
// base URL is required at API creation. Use the first route.
var defaultServiceUrl = dedupedRoutes[0].endpoint

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'openai-realtime-webrtc'
  parent: apimService
  properties: {
    apiType: 'http'
    type: 'http'
    description: 'Azure OpenAI Realtime WebRTC API (SDP exchange + ephemeral token minting). Routes per-deployment to the backing Foundry instance and bypasses APIM Backend-resource credentials so a caller ephemeral token can flow through untouched.'
    displayName: 'Realtime WebRTC API'
    path: '${inferenceAPIPath}/realtime'
    serviceUrl: defaultServiceUrl
    protocols: [
      'https'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: requireSubscriptionKey
  }
}

// POST /calls — SDP exchange (ephemeral Bearer).
resource callsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'post-calls'
  parent: api
  properties: {
    displayName: 'Realtime SDP exchange'
    method: 'POST'
    urlTemplate: '/calls'
    description: 'SDP offer/answer exchange for WebRTC. Caller supplies an ephemeral Bearer token minted from /client_secrets; body is application/sdp.'
  }
}

// POST /client_secrets — mint ephemeral token (AAD/MI Bearer).
resource clientSecretsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  name: 'post-client-secrets'
  parent: api
  properties: {
    displayName: 'Mint ephemeral realtime token'
    method: 'POST'
    urlTemplate: '/client_secrets'
    description: 'Mint an ephemeral realtime session token. Caller supplies an AAD/MI Bearer token; body is application/json describing the session config.'
  }
}

resource aiGatewayTag 'Microsoft.ApiManagement/service/tags@2024-06-01-preview' = {
  name: 'ai-gateway'
  parent: apimService
  properties: {
    displayName: 'AI Gateway'
  }
}

resource aiGatewayApiTag 'Microsoft.ApiManagement/service/apis/tags@2024-06-01-preview' = {
  name: 'ai-gateway'
  parent: api
  dependsOn: [aiGatewayTag]
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: api
  dependsOn: [callsOperation, clientSecretsOperation]
  properties: {
    format: 'rawxml'
    value: apiPolicyXml
  }
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (!empty(apimLoggerId)) {
  parent: api
  name: 'azuremonitor'
  properties: {
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    logClientIp: true
    loggerId: apimLoggerId
    sampling: {
      samplingType: 'fixed'
      percentage: json('100')
    }
    frontend: {
      request: logSettings
      response: logSettings
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}

resource apiDiagnosticsAppInsights 'Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01' = if (!empty(appInsightsId) && !empty(appInsightsInstrumentationKey)) {
  name: 'applicationinsights'
  parent: api
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: resourceId(resourceGroup().name, 'Microsoft.ApiManagement/service/loggers', apiManagementName, 'appinsights-logger')
    metrics: true
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: logSettings
      response: logSettings
    }
    backend: {
      request: logSettings
      response: logSettings
    }
  }
}

// ------------------
//    OUTPUTS
// ------------------

output apiId string = api.id
output apiName string = api.name
output apiPath string = api.properties.path
