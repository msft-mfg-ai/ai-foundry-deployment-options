/**
 * @module realtime-ws-api
 * @description Creates a WebSocket API in APIM that fronts Azure OpenAI
 * Realtime (speech/audio) deployments. Unlike the HTTP inference APIs, a
 * WebSocket API cannot use backend *pools* (a realtime connection is 1:1 and
 * can't be load-balanced), so this API routes per-deployment to a concrete APIM
 * backend with a `wss://` URL via a custom `onHandshake` policy
 * (../realtime-routing-policy.xml).
 *
 * The API is exposed at `{inferenceAPIPath}/openai/realtime` — a strictly
 * longer path prefix than the HTTP passthrough API (`{inferenceAPIPath}`), so
 * APIM's longest-prefix API selection routes realtime handshakes here and all
 * other traffic to the passthrough. Clients reuse the same base
 * `https://{apim}/{inferenceAPIPath}` endpoint; the openai SDK builds the
 * realtime URL as `{endpoint}/openai/realtime?...`.
 */

// ------------------
//    PARAMETERS
// ------------------

@description('The name of the API Management instance.')
param apiManagementName string

@description('Id of the APIM Logger for Azure Monitor diagnostics. Empty disables the azuremonitor diagnostic.')
param apimLoggerId string = ''

@description('Base path of the inference API surface (without leading/trailing slash). The realtime API is created at `{inferenceAPIPath}/openai/realtime`.')
param inferenceAPIPath string = 'inference'

@description('Realtime deployment routes. One entry per realtime model deployment, mapping the deployment name to a concrete APIM backend and backing instance wss base URL.')
param realtimeRoutes realtimeRouteType[]

@description('Pre-rendered `<validate-jwt>` block injected into the onHandshake policy. Empty string disables inbound caller-token validation.')
param jwtValidationXml string = ''

@description('Whether to require an APIM subscription key on the handshake. Under ProjectManagedIdentity auth this is false (the JWT policy gates the caller).')
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
@description('A single realtime deployment route: the deployment/model name, APIM backend ID, and backing instance wss base URL.')
type realtimeRouteType = {
  @description('Deployment/model name as used in the realtime URL query (e.g. "gpt-realtime", "gpt-4o-realtime-preview").')
  deploymentName: string

  @description('Concrete APIM backend resource name for this realtime deployment.')
  backendId: string

  @description('Backing instance wss base URL, e.g. "wss://acct.openai.azure.com/openai/realtime".')
  endpoint: string
}

// ------------------
//    VARIABLES
// ------------------

import { requestLogSettings } from '../log-settings.bicep'
var logSettings = requestLogSettings

// Build the deployment -> concrete APIM backend map embedded into the policy.
// Dedupe by deployment name (first route wins) so multiple instances serving
// the same realtime deployment collapse to a single backend (no LB on WebSocket
// connections).
var dedupedRoutes = reduce(
  realtimeRoutes,
  [],
  (acc, r) => contains(map(acc, x => x.deploymentName), r.deploymentName) ? acc : concat(acc, [r])
)
var routingMapObject = reduce(
  dedupedRoutes,
  {},
  (acc, r) => union(acc, { '${r.deploymentName}': r.backendId })
)
var routingMapJson = string(routingMapObject)

// XML-encode the JSON so it survives intact inside the policy attribute value.
// APIM decodes entity refs before the policy engine sees the string, so
// context.Variables[…] receives the original JSON. Encode `&` first.
var routingMapEncoded = replace(
  replace(replace(replace(routingMapJson, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
  '"',
  '&quot;'
)

var onHandshakePolicyXml = replace(
  replace(loadTextContent('../realtime-routing-policy.xml'), '{ROUTING_MAP}', routingMapEncoded),
  '{JWT_VALIDATION}',
  jwtValidationXml
)

// Default backend (serviceUrl) — the policy overrides it per request, but a
// valid wss serviceUrl is required at API creation. Use the first route.
var defaultServiceUrl = dedupedRoutes[0].endpoint

// ------------------
//    RESOURCES
// ------------------

resource apimService 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apiManagementName
}

@batchSize(1)
resource realtimeBackends 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = [
  for route in realtimeRoutes: {
    parent: apimService
    name: route.backendId
    properties: {
      description: 'Realtime WebSocket backend for deployment ${route.deploymentName}'
      url: route.endpoint
      protocol: 'http'
      credentials: {
        #disable-next-line BCP037
        managedIdentity: {
          resource: 'https://cognitiveservices.azure.com'
        }
      }
    }
  }
]

// https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis
resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  name: 'realtime-audio'
  parent: apimService
  properties: {
    apiType: 'websocket'
    type: 'websocket'
    description: 'Azure OpenAI Realtime (speech/audio) WebSocket API. Routes per-deployment to the backing Foundry instance.'
    displayName: 'Realtime Audio API'
    path: '${inferenceAPIPath}/openai/realtime'
    serviceUrl: defaultServiceUrl
    protocols: [
      'wss'
    ]
    subscriptionKeyParameterNames: {
      header: 'api-key'
      query: 'api-key'
    }
    subscriptionRequired: requireSubscriptionKey
  }
}

// onHandshake is an immutable, auto-created system operation on every WebSocket
// API — reference it as existing to attach the routing policy.
resource onHandshakeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  name: 'onHandshake'
  parent: api
}

resource onHandshakePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  name: 'policy'
  parent: onHandshakeOperation
  dependsOn: [realtimeBackends]
  properties: {
    format: 'rawxml'
    value: onHandshakePolicyXml
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
