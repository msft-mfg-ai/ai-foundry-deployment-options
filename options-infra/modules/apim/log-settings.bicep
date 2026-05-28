// Shared APIM diagnostic log settings.
// One source of truth for the header whitelist + body size used by every
// API in every gateway sample, so the dashboard / saved-queries can rely on
// a consistent set of dimensions being present in ApiManagementGatewayLogs.
//
// APIM has no wildcard for header capture — we must explicitly list every
// header we want logged. The list below is curated to:
//   - capture useful Foundry-side identifiers Foundry's ModelGateway sends
//     (x-ms-foundry-*, openai-project, traceparent)
//   - capture the canonical x-caller-* headers our caller-identity policy
//     fragment sets, regardless of auth path
//   - capture rate-limit / region / cluster signals from the backend response
//   - exclude infra noise (k8se, envoy, X-Forwarded-*) and secrets

// Headers logged on inbound request side (frontend.request, backend.request).
@export()
var requestHeaders array = [
  // Foundry-sent identifiers (verified via dev-tunnel echo capture)
  'x-ms-foundry-project-id'
  'openai-project'
  'x-ms-foundry-model-id'
  'x-ms-foundry-agent-id'
  // Distributed tracing / correlation
  'traceparent'
  'tracestate'
  'Correlation-Context'
  'x-ms-client-request-id'
  'x-ms-correlation-request-id'
  'x-ms-request-id'
  'X-Request-ID'
  'Request-Id'
  // Set by our caller-identity policy fragment
  'x-caller-name'
  'x-caller-id'
  'x-caller-foundry'
  'x-caller-project'
  'x-caller-priority'
  'x-foundry-name'
  // Standard HTTP (non-secret)
  'Content-Type'
  'User-Agent'
  'Accept'
]

// Headers logged on response side (frontend.response, backend.response).
@export()
var responseHeaders array = [
  // Backend (Foundry / Anthropic / OpenAI) response signals
  'x-ms-region'
  'x-ratelimit-remaining-tokens'
  'x-ratelimit-remaining-requests'
  'x-ratelimit-limit-tokens'
  'x-ratelimit-limit-requests'
  'azureml-served-by-cluster'
  'apim-request-id'
  // Caller echoes (so response logs can be filtered without joining)
  'x-caller-name'
  'x-caller-id'
  'x-caller-project'
  'x-caller-foundry'
  // Backend routing / error context (set by APIM policies that support it)
  'x-backend-pool'
  'x-backend-type'
  'x-route-trace'
  'x-retry-count'
  'x-spillover'
  'x-error-reason'
  'x-error-source'
]

// Maximum body size APIM will capture per direction.
// APIM `body.bytes` on diagnostic settings is capped at 8192. Full LLM message
// capture (up to 262144 bytes) is configured separately via the
// `largeLanguageModel.requests/responses.maxSizeInBytes` setting in
// inference-api.bicep — that field is the high-volume content channel.
@export()
var maxBodyBytes int = 8192

// Request-side log settings — passed to frontend.request and backend.request.
@export()
var requestLogSettings = {
  headers: requestHeaders
  body: {
    bytes: maxBodyBytes
  }
}

// Response-side log settings — passed to frontend.response and backend.response.
@export()
var responseLogSettings = {
  headers: responseHeaders
  body: {
    bytes: maxBodyBytes
  }
}
