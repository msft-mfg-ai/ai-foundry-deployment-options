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
import { subscriptionType, hostnameConfigurationType } from 'v2/apim.bicep'

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
@allowed(['Consumption', 'Developer', 'Basic', 'Basicv2', 'Standard', 'Standardv2', 'Premium', 'Premiumv2'])
param apimSku string = 'Basicv2'

@description('Also deploy a spec-backed AzureOpenAI inference API (with per-operation definitions, model-discovery endpoints, and the APIM test console) alongside the Foundry-facing passthrough. Both APIs share the same per-model routing fragment, so they hit the same backend pools.')
param deploySpecApi bool = true

@description('URL path for the spec-backed AzureOpenAI API. Must not collide with the passthrough path (`inference/openai`). The AzureOpenAI inference-api module appends `/openai`, so a value of `openai` exposes the API at `…/openai/openai/…` — use `azure` (default) for `…/azure/openai/…`.')
param specApiPath string = 'azure'

@description('Tenant IDs whose Entra ID tokens are accepted as inbound auth. When non-empty, both inference APIs inject a `<validate-jwt>` block that requires `aud=https://cognitiveservices.azure.com` and lists one issuer per tenant (both v1 `sts.windows.net/{tid}/` and v2 `login.microsoftonline.com/{tid}/v2.0`). Empty (default) = no inbound JWT validation — backward-compatible.')
param acceptedTenantIds string[] = []

param logAnalyticsWorkspaceResourceId string
param appInsightsInstrumentationKey string = ''
param appInsightsResourceId string = ''

// -- Networking / SKU-variant params (all optional, pass-through to v2/apim.bicep) -
// These let per-model-gateway.bicep host the public-only, internal-VNET, External-VNET+PE,
// custom-domain, and Premium variants without forking the orchestrator.

@description('VNet integration mode for the APIM service. None (default) = public, External = injected with internet ingress, Internal = injected with no public endpoint.')
@allowed(['None', 'External', 'Internal'])
param virtualNetworkType string = 'None'

@description('Subnet resource ID for the APIM injection. Required when virtualNetworkType is External or Internal.')
param subnetResourceId string?

@description('Public network access on the APIM service. Leave Enabled for public deployments. When opting into PE attachment (peSubnetResourceId), pass Disabled to trigger the post-PE flip step.')
@allowed(['Enabled', 'Disabled'])
param publicNetworkAccess string = 'Enabled'

@description('Subnet resource ID hosting the APIM private endpoint. When non-empty, the module attaches a private endpoint (with the privatelink.azure-api.net DNS zone) and — if publicNetworkAccess=Disabled — runs a follow-up APIM deploy to flip public access off. Service-creation itself uses publicNetworkAccess=null in that case (Azure blocks setting Disabled on initial create).')
param peSubnetResourceId string = ''

@description('Custom hostname configurations for the APIM gateway (e.g. proxy custom domain backed by a Key Vault cert). Empty = use the default *.azure-api.net hostname.')
param hostnameConfigurations hostnameConfigurationType[] = []

@description('APIM managed-identity mode. UserAssigned is required when hostnameConfigurations reference a Key Vault cert.')
@allowed(['SystemAssigned', 'UserAssigned', 'SystemAssigned, UserAssigned'])
param apimManagedIdentityType string = 'SystemAssigned'

@description('User-assigned managed identity resource ID. Required when apimManagedIdentityType includes UserAssigned (KV-cert custom domain).')
param apimUserAssignedManagedIdentityResourceId string?

// -- Custom domain (Internal VNet variants like Premium) --------------------
@description('Custom apex domain (e.g. "cloud.example.com"). When set, the gateway is exposed at https://apim.{customDomain}/… via a Key Vault-sourced certificate. Requires keyVaultName + certificateKeyVaultUri + a UAMI with KV Certificate User + Secrets User. Leave empty to use the default *.azure-api.net hostname.')
param customDomain string = ''

@description('Key Vault name holding the custom-domain certificate. Required when customDomain is set — the gateway grants its UAMI Certificate User + Secrets User on this vault.')
param keyVaultName string = ''

@description('Key Vault secret URI of the custom-domain certificate (e.g. https://kv-xxx.vault.azure.net/secrets/customdomaincert). Required when customDomain is set.')
param certificateKeyVaultUri string = ''

@description('Extra VNet resource IDs to link to the privatelink.azure-api.net (and customDomain) DNS zones — useful when APIM lives in its own VNet but callers live in a peered one. Only applied when virtualNetworkType=Internal.')
param vnetResourceIdsForDnsLink string[] = []

// -- Constants ----------------------------------------------------------------
// Passthrough API resource name. Must match what we pass to the v2 module
// below so the discovery operations (added via `existing` references) can find
// it deterministically.
var passthroughApiName = 'inference-api'

// -- Multi-tenant inbound JWT validation -------------------------------------
// Replaces the `{JWT_VALIDATION}` token in policy-per-model.xml. When the
// caller passes no tenants we emit a comment so the policy stays open (current
// behaviour). Each accepted tenant contributes BOTH the v1 (`sts.windows.net`)
// and v2 (`login.microsoftonline.com/.../v2.0`) issuer URLs since AAD tokens
// can carry either depending on how the caller acquired them.
var issuersXml = empty(acceptedTenantIds)
  ? ''
  : join(map(acceptedTenantIds, tid => '<issuer>https://sts.windows.net/${tid}/</issuer><issuer>https://login.microsoftonline.com/${tid}/v2.0</issuer>'), '')
var jwtValidationXml = empty(acceptedTenantIds)
  ? '<!-- multi-tenant JWT validation disabled (acceptedTenantIds is empty) -->'
  : '<validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized"><openid-config url="https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" /><audiences><audience>https://cognitiveservices.azure.com</audience><audience>https://cognitiveservices.azure.com/</audience></audiences><issuers>${issuersXml}</issuers></validate-jwt>'

var policyPerModelXml = replace(loadTextContent('policy-per-model.xml'), '{JWT_VALIDATION}', jwtValidationXml)

// -- Custom domain validation + synthesis -----------------------------------
// When customDomain is set, every dependency (cert URI + KV name + UAMI) must
// also be set — fail fast with a clear error so the caller can't silently
// deploy a half-configured custom-domain gateway.
var customDomainEnabled = !empty(customDomain)
var customDomainValid = customDomainEnabled && (empty(certificateKeyVaultUri) || empty(keyVaultName) || empty(apimUserAssignedManagedIdentityResourceId))
  ? fail('customDomain requires certificateKeyVaultUri, keyVaultName, and apimUserAssignedManagedIdentityResourceId to all be set.')
  : true

// PremiumV2 only supports 'Proxy' and 'DeveloperPortal' hostname types for
// custom domains — Proxy is what gateway clients hit, so we register that one.
// Callers can still override by passing hostnameConfigurations explicitly.
var synthesizedHostnameConfigurations hostnameConfigurationType[] = customDomainEnabled
  ? [
      {
        type: 'Proxy'
        hostName: 'apim.${customDomain}'
        certificateSource: 'KeyVault'
        keyVaultId: certificateKeyVaultUri
      }
    ]
  : []

var effectiveHostnameConfigurations = !empty(hostnameConfigurations)
  ? hostnameConfigurations
  : synthesizedHostnameConfigurations

// Internal VNet variant: derive the gateway's own VNet (parent of subnetResourceId)
// so the apim-dns module can link the *.azure-api.net (and customDomain) zones
// to it. Other variants ignore these.
var internalVnetMode = virtualNetworkType == 'Internal' && !empty(subnetResourceId)
var subnetIdParts = internalVnetMode ? split(subnetResourceId!, '/') : []
var subnetNameForDns = internalVnetMode ? last(subnetIdParts) : ''
var apimOwnVnetResourceId = internalVnetMode
  ? substring(subnetResourceId!, 0, length(subnetResourceId!) - length('/subnets/${subnetNameForDns}'))
  : ''
var dnsLinkVnetResourceIds = internalVnetMode ? union(vnetResourceIdsForDnsLink, [apimOwnVnetResourceId]) : []

// -- Derived ------------------------------------------------------------------
var connectionPerProject = !empty(aiFoundryProjectNames)
var openAIStaticModels = filter(staticModels, m => toLower(m.properties.model.format) != 'anthropic')
var anthropicStaticModels = filter(staticModels, m => toLower(m.properties.model.format) == 'anthropic')
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
// When peSubnetResourceId is set AND the caller wants publicNetworkAccess=Disabled
// (private-only), Azure rejects setting Disabled on initial creation
// ("Blocking all public network access ... is not enabled during service creation").
// We mirror the legacy ai-gateway-pe.bicep dance: create with the field null,
// attach the PE, then re-deploy with publicNetworkAccess=Disabled.
var attachingPrivateEndpoint = !empty(peSubnetResourceId)
var deferPublicAccessFlip = attachingPrivateEndpoint && publicNetworkAccess == 'Disabled'
var initialPublicNetworkAccess = deferPublicAccessFlip ? null : publicNetworkAccess

var apimServiceName = 'apim-ai-${resourceToken}'

module apimService 'v2/apim.bicep' = {
  name: 'apim-deployment'
  params: {
    apiManagementName: apimServiceName
    location: location
    tags: tags
    resourceSuffix: resourceToken
    apimSku: apimSku
    lawId: logAnalyticsWorkspaceResourceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: virtualNetworkType
    subnetResourceId: subnetResourceId
    #disable-next-line BCP036
    publicNetworkAccess: initialPublicNetworkAccess
    hostnameConfigurations: effectiveHostnameConfigurations
    apimManagedIdentityType: apimManagedIdentityType
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
  }
}

// ============================================================================
// -- Internal-VNet DNS linking (privatelink.azure-api.net + custom domain)
// ============================================================================
// Required when virtualNetworkType=Internal: APIM has no public endpoint, so
// callers in the VNet resolve `*.azure-api.net` via a private DNS zone linked
// to the gateway's VNet (and any peered VNets the caller passes in).
module apimDns 'apim-dns.bicep' = if (internalVnetMode) {
  name: 'apim-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apimService.outputs.apimPrivateIp
    vnetResourceIds: dnsLinkVnetResourceIds
    apimName: apimService.outputs.name
  }
}

module apimCustomDns 'apim-dns.bicep' = if (internalVnetMode && customDomainEnabled) {
  name: 'apim-custom-dns-configuration'
  params: {
    tags: tags
    apimIpAddress: apimService.outputs.apimPrivateIp
    vnetResourceIds: dnsLinkVnetResourceIds
    apimName: 'apim'
    zoneName: customDomain
  }
}

// ============================================================================
// -- APIM private endpoint (opt-in via peSubnetResourceId)
// ============================================================================
module apimPrivateEndpoint 'apim-pe.bicep' = if (attachingPrivateEndpoint) {
  name: 'apim-pe-deployment'
  params: {
    tags: tags
    location: location
    apimName: apimService.outputs.name
    peSubnetResourceId: peSubnetResourceId
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
    apiManagementName: apimService.outputs.name
    apimLoggerId: apimService.outputs.loggerId
    aiServicesConfig: []
    inferenceAPIType: 'Other'
    inferenceAPIPath: 'inference'
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
    policyXml: policyPerModelXml
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
module aiGatewayConnectionOpenAIStatic '../ai/connection-apim-gateway.bicep' = if (!connectionPerProject && !empty(openAIStaticModels)) {
  name: 'apim-connection-openai-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-openai-static'
    apimResourceId: apimService.outputs.id
    apiName: inferenceApi.outputs.apiName
    apimSubscriptionName: first(apimService.outputs.apimSubscriptions).name
    isSharedToAll: true
    staticModels: openAIStaticModels
    inferenceAPIVersion: '2025-03-01-preview'
    authType: gatewayAuthenticationType
  }
}

module aiGatewayConnectionAnthropicStatic '../ai/connection-apim-gateway.bicep' = if (!connectionPerProject && !empty(anthropicStaticModels)) {
  name: 'apim-connection-anthropic-static'
  params: {
    aiFoundryName: aiFoundryName
    connectionName: 'apim-${resourceToken}-anthropic-static'
    apimResourceId: apimService.outputs.id
    apiName: inferenceApi.outputs.apiName
    apimSubscriptionName: first(apimService.outputs.apimSubscriptions).name
    isSharedToAll: true
    staticModels: anthropicStaticModels
    inferenceAPIVersion: '2025-03-01-preview'
    deploymentInPath: 'false'
    authType: gatewayAuthenticationType
  }
}

module aiGatewayProjectConnectionOpenAIStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connectionPerProject && !empty(openAIStaticModels)) {
    name: 'apim-connection-openai-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-openai-static-for-${projectName}'
      apimResourceId: apimService.outputs.id
      apiName: inferenceApi.outputs.apiName
      apimSubscriptionName: first(filter(apimService.outputs.apimSubscriptions, (sub) => contains(sub.name, projectName))).name
      isSharedToAll: false
      staticModels: openAIStaticModels
      inferenceAPIVersion: '2025-03-01-preview'
      authType: gatewayAuthenticationType
    }
  }
]

module aiGatewayProjectConnectionAnthropicStatic '../ai/connection-apim-gateway.bicep' = [
  for projectName in aiFoundryProjectNames: if (connectionPerProject && !empty(anthropicStaticModels)) {
    name: 'apim-connection-anthropic-static-${projectName}'
    params: {
      aiFoundryName: aiFoundryName
      aiFoundryProjectName: projectName
      connectionName: 'apim-${resourceToken}-anthropic-static-for-${projectName}'
      apimResourceId: apimService.outputs.id
      apiName: inferenceApi.outputs.apiName
      apimSubscriptionName: first(filter(apimService.outputs.apimSubscriptions, (sub) => contains(sub.name, projectName))).name
      isSharedToAll: false
      staticModels: anthropicStaticModels
      inferenceAPIVersion: '2025-03-01-preview'
      deploymentInPath: 'false'
      authType: gatewayAuthenticationType
    }
  }
]

// ============================================================================
// -- Post-PE: flip publicNetworkAccess to Disabled
// ============================================================================
// Azure rejects publicNetworkAccess=Disabled on the initial APIM create when a
// private endpoint is being attached. We deferred the flag and now re-deploy
// the same APIM resource with it Disabled — after every child resource has
// been created (and so could still be reached over the public endpoint).
// This is intentionally a no-op when peSubnetResourceId is empty OR when the
// caller wants the gateway to keep public access (publicNetworkAccess=Enabled).
module apimServiceUpdate 'v2/apim.bicep' = if (deferPublicAccessFlip) {
  name: 'apim-update-deployment'
  dependsOn: [
    apimPrivateEndpoint
    callerIdentityFragment
    perModelRoutingFragment
    foundryBackends
    inferenceApi
    inferenceApiSpec
    passthroughDiscovery
    specApiDiscovery
    aiGatewayConnectionOpenAIStatic
    aiGatewayConnectionAnthropicStatic
    aiGatewayProjectConnectionOpenAIStatic
    aiGatewayProjectConnectionAnthropicStatic
  ]
  params: {
    apiManagementName: apimServiceName
    location: location
    tags: tags
    resourceSuffix: resourceToken
    apimSku: apimSku
    lawId: logAnalyticsWorkspaceResourceId
    appInsightsInstrumentationKey: appInsightsInstrumentationKey
    appInsightsId: appInsightsResourceId
    apimSubscriptionsConfig: subscriptions
    virtualNetworkType: virtualNetworkType
    subnetResourceId: subnetResourceId
    publicNetworkAccess: 'Disabled'
    hostnameConfigurations: effectiveHostnameConfigurations
    apimManagedIdentityType: apimManagedIdentityType
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
  }
}

// ============================================================================
// -- Custom-domain hostname update (Internal VNet variants)
// ============================================================================
// Mirrors ai-gateway-premium.bicep's `apim_update` step: a lightweight
// re-deploy that only touches the hostname configurations (and grants the
// APIM UAMI Certificate User + Secrets User on the KV holding the cert), so
// we don't have to re-deploy the full APIM resource with all its APIs.
// Gated on customDomainEnabled — irrelevant for public / PE variants whose
// custom hostnames (if any) are applied during the initial create.
module apimHostnameUpdate 'apim-hostname-update.bicep' = if (customDomainEnabled && internalVnetMode) {
  name: 'apim-hostname-update-deployment'
  dependsOn: [
    apimDns
    apimCustomDns
    callerIdentityFragment
    perModelRoutingFragment
    foundryBackends
    inferenceApi
    inferenceApiSpec
    passthroughDiscovery
    specApiDiscovery
    aiGatewayConnectionOpenAIStatic
    aiGatewayConnectionAnthropicStatic
    aiGatewayProjectConnectionOpenAIStatic
    aiGatewayProjectConnectionAnthropicStatic
  ]
  params: {
    tags: tags
    location: location
    resourceSuffix: resourceToken
    apimSku: apimSku
    virtualNetworkType: virtualNetworkType
    subnetResourceId: subnetResourceId
    #disable-next-line BCP036
    publicNetworkAccess: null
    apimUserAssignedManagedIdentityResourceId: apimUserAssignedManagedIdentityResourceId
    apimManagedIdentityType: apimManagedIdentityType
    apimPrincipalId: apimService.outputs.principalId
    hostnameConfigurations: effectiveHostnameConfigurations
    keyVaultName: keyVaultName
  }
}

// -- Outputs ------------------------------------------------------------------
output apimResourceId string = apimService.outputs.id
output apimName string = apimService.outputs.name
output apimPrincipalId string = apimService.outputs.principalId
output apimGatewayUrl string = apimService.outputs.gatewayUrl
output apimAppInsightsLoggerId string = apimService.outputs.loggerId
output backendNames array = foundryBackends.outputs.backendNames
output poolNames array = foundryBackends.outputs.poolNames
