// foundry-byo-vnet-teams
// ============================================================================
// BYO VNet deployment with N Foundry agents published to Teams.
//
// Phase A (Foundry only): leave AGENT_NAMES empty in azd env. Bicep deploys
// the VNet + Foundry stack only, skipping all bot resources.
// Phase B (multi-agent): preprovision script creates one AAD app reg per
// agent (no secret) plus a shared `teams-app-backend` reg (with secret).
// Bicep then provisions:
//   - 1 Foundry agent per name
//   - 2 Bot Services per name (direct → activityprotocol, proxy → container)
//   - 1 shared container app with route-bound JWT validation + OBO via the
//     backend reg's client secret
// FICs (no per-bot secrets) are created in `postprovision-multi-agent.sh`
// after the container UAMI exists.
// ============================================================================

targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'

param location string = resourceGroup().location
param projectsCount int = 1
param apiServices apiType[] = [] // External MCP/OpenAPI services

// ---------------------------------------------------------------------------
// Multi-agent inputs (populated by `preprovision-multi-agent`).
// All four are empty in Phase A — bicep then skips bot resources entirely.
// ---------------------------------------------------------------------------
@description('Agent names. Empty array → Phase A (Foundry only, no bots).')
param agentNames string[] = []

// Typed dictionary: keys are agent names, values are AAD application (client)
// IDs (GUIDs as strings). The preprovision script writes this object to azd
// env as JSON and bicepparam parses it. Each app reg has NO secret — outbound
// BF tokens are minted via FIC trusting the container UAMI.
@description('Map of agent name → AAD app id (the bot identity for proxy bots AND the per-agent Teams SSO target).')
param agentAppRegs agentAppRegsType = {}

type agentAppRegsType = {
  *: string
}

// Per-agent SSO client secrets. Bundled as a single @secure() object so the
// values are treated as secrets end-to-end (param value, module passthrough,
// Container App secret). Indexing this object inside a `for` loop returns a
// secure expression that bicep correctly routes into the bot module's
// @secure() ssoClientSecret param.
@secure()
@description('Map of agent name → AAD app client secret. Used by each per-bot ABS OAuth connection for OBO (Teams SSO token → Foundry user-impersonation token).')
param agentAppSecrets object = {}

@description('Shared Teams App backend AAD app id — used ONLY for /admin OIDC sign-in + OBO into Foundry. NOT used for bot SSO (each agent reg is its own SSO target).')
param teamsAppBackendId string = ''

@secure()
@description('Client secret of the Teams App backend AAD app. Stored as a Container App secret (no Key Vault).')
param teamsAppBackendSecret string = ''

var deployBots = !empty(agentNames) && !empty(teamsAppBackendId)
// Each per-bot OAuth connection uses the same connection name. The connection
// is parented on each bot resource so they're distinct objects despite the
// shared name — the proxy's TeamsApp__SsoConnectionName env var stays a single
// constant.
var ssoConnectionName = 'foundry-sso'
var teamsAppIdentifierUri = empty(teamsAppBackendId) ? '' : 'api://${teamsAppBackendId}'

// ---------------------------------------------------------------------------
// Direct-bot endpoint mode
// ---------------------------------------------------------------------------
// The "direct" bot's msaAppId is the Foundry agent's ServiceIdentity SP, and
// Bot Service POSTs each activity to whatever URL we configure here. Two
// strategies:
//
//   'foundry'      → endpoint = Foundry's activityprotocol URL directly.
//                    Simplest topology; requires Foundry public network
//                    access = Enabled (BF channels live on the public
//                    internet and must reach the endpoint).
//
//   'passthrough'  → endpoint = container app /api/passthrough/* route,
//                    which is a YARP reverse proxy that forwards 1:1 to the
//                    same Foundry activityprotocol URL (same body, same JWT,
//                    same query string). Required when Foundry public access
//                    is Disabled: BF traffic terminates on the container
//                    (which reaches Foundry over the private endpoint) so
//                    Foundry itself stays unreachable from the internet.
//
// Default is 'passthrough' because the whole point of this template is the
// PE-ready topology. Flip to 'foundry' for simpler debugging or when you
// know public access will remain enabled.
@allowed(['foundry', 'passthrough'])
@description('Endpoint the direct bot points at: "foundry" = activityprotocol URL directly (needs Foundry public access); "passthrough" = via container YARP route (works with PE-only Foundry).')
param directBotEndpointMode string = 'passthrough'

var tags = {
  'created-by': 'foundry-byo-vnet-teams'
  'hidden-title': 'Foundry Standard - BYO VNet + Multi-agent Teams'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// ---------------------------------------------------------------------------
// VNet + Log Analytics (always deployed)
// ---------------------------------------------------------------------------
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
  }
}

module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

// ---------------------------------------------------------------------------
// Foundry stack (always deployed)
// ---------------------------------------------------------------------------
module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: ''
    aiAccountNameResourceGroupName: ''
  }
}

var deployments = [
  {
    name: 'gpt-5.2'
    properties: {
      model: {
        format: 'OpenAI'
        name: 'gpt-5.2'
        version: '2025-12-11'
      }
    }
    sku: {
      name: 'GlobalStandard'
      capacity: 20
    }
  }
]

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: ''
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: deployments
  }
}

module project_identities '../modules/iam/identity.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-identity-${resourceToken}'
    params: {
      tags: tags
      location: location
      identityName: 'ai-project-${i}-identity-${resourceToken}'
    }
  }
]

var projectNames = [for i in range(1, projectsCount): 'ai-project-${resourceToken}-${i}']

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundryName: foundry.outputs.FOUNDRY_NAME
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      projectId: i
      project_name: projectNames[i - 1]
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: project_identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module mcp_apis '../modules/apps/apps-private-link.bicep' = {
  name: 'mcp-apis-private-link-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    externalApis: apiServices
  }
}

// Foundry private endpoint (+ associated DNS zone records) so the proxy
// container can reach Foundry over the VNet. Public network access on the
// Foundry account stays Enabled for now — flip the `publicNetworkAccess`
// param on the foundry module to 'Disabled' to lock it down once you've
// verified that all bot/proxy traffic flows through the PE.
module foundry_pe '../modules/networking/ai-pe-dns.bicep' = {
  name: 'foundry-pe-${resourceToken}'
  params: {
    tags: tags
    location: location
    aiAccountName: foundry.outputs.FOUNDRY_NAME
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    vnetId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
  }
}

// ---------------------------------------------------------------------------
// Phase B: per-agent Foundry agents and Bot Services
// All resources below this point are skipped when AGENT_NAMES is empty.
// ---------------------------------------------------------------------------

@batchSize(1)
module teamsAgents '../modules/ai/foundry-agent.bicep' = [for agentName in agentNames: {
  name: 'create-agent-${agentName}-${resourceToken}'
  params: {
    tags: union(tags, { SecurityControl: 'Ignore' })
    location: location
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    aiFoundryProjectName: projectNames[0]
    agentName: agentName
    createAgent: true
    model: 'gpt-5.2'
    instructions: 'You are a helpful assistant exposed via Microsoft Teams.'
    resourceSuffix: resourceToken
  }
  dependsOn: [
    projects
  ]
}]

// Direct bot — Foundry's auto-created ServiceIdentity SP appId is the
// bot's msaAppId. BF channels mint tokens with aud = msaAppId; Foundry's
// activityprotocol validates against this same appId. No FIC needed: the
// Foundry SP already exists with whatever credentials Foundry uses internally.
//
// Endpoint is chosen by `directBotEndpointMode`:
//   - 'passthrough' (default) → container's /api/passthrough/* YARP route,
//     which forwards 1:1 to Foundry's activityprotocol URL. Lets Foundry
//     have public network access disabled while still serving BF traffic,
//     because all inbound HTTPS terminates on the container (which has VNet
//     connectivity to Foundry's PE) instead of Foundry directly.
//     See proxy repo src/AgentChat/Passthrough/ for the implementation.
//   - 'foundry' → straight at Foundry's activityprotocol URL. Requires
//     Foundry public access = Enabled. No container app dependency for the
//     direct bot path (proxy bot still needs it for /api/messages/*).
module botServicesDirect '../modules/bot/bot-service.bicep' = [for (agentName, i) in agentNames: if (deployBots) {
  name: 'bot-direct-${agentName}-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'bot-direct-${agentName}-${resourceToken}'
    displayName: agentName
    endpoint: directBotEndpointMode == 'foundry'
      ? 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${projectNames[0]}/agents/${agentName}/endpoint/protocols/activityprotocol?api-version=2025-11-15-preview'
      : '${teamsProxy!.outputs.CONTAINER_APP_FQDN}/api/passthrough/${foundry.outputs.FOUNDRY_NAME}/${projectNames[0]}/${agentName}?api-version=2025-11-15-preview'
    disableLocalAuth: false
    msaAppType: 'SingleTenant'
    msaAppId: teamsAgents[i].outputs.agentIdentityAppId
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
  }
}]

// ---------------------------------------------------------------------------
// Container App environment + UAMI + Cosmos (proxy infra)
// Always deployed even in Phase A so that re-running with agents added
// doesn't have to recreate them. (Cheap to keep idle; UAMI has no cost.)
// ---------------------------------------------------------------------------
module managedEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'managed-environment'
  params: {
    location: location
    tags: tags
    appInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    name: 'aca${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    storages: []
    publicNetworkAccess: 'Enabled'
    infrastructureSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.acaSubnet.resourceId
  }
}

// Compute identity for the proxy container: Cosmos data-plane access,
// App Insights, and the FIC subject for outbound BF token exchange. NOT
// used as a bot msaAppId — each bot has its own SingleTenant app reg.
// (FIC: subject = principalId of this UAMI, audience = api://AzureADTokenExchange.
// FICs are created in postprovision-multi-agent.sh after this UAMI exists.)
module teamsProxyIdentity '../modules/iam/identity.bicep' = {
  name: 'teams-proxy-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'teams-proxy-identity-${resourceToken}'
  }
}

module botCosmos '../modules/db/cosmos.bicep' = {
  name: 'bot-cosmosdb'
  params: {
    location: location
    tags: tags
    accountName: 'bot-cosmosdb-${resourceToken}'
    appPrincipalId: teamsProxyIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    cosmosDbPrivateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.documents.azure.com'].resourceId
  }
}

// ---------------------------------------------------------------------------
// Bots__Routes — JSON array of {AgentName, ProxyAppId, DirectAppId} used by
// the container:
//   - JWT middleware: binds incoming URL path → expected `aud` (ProxyAppId)
//     so a token issued for bot A can't be replayed against bot B's URL.
//   - FIC factory: allow-list of valid proxy appIds for outbound BF auth.
//   - ManifestController: renders two download buttons per agent — one for
//     the direct bot (Foundry SP identity) and one for the proxy bot
//     (our pre-created reg).
//
// Built by `bots-routes.bicep` (a module — required because Bicep refuses
// runtime-derived for-expressions inside `var`s and property values; module
// outputs ARE legal runtime values in upstream properties).
// ---------------------------------------------------------------------------
module botsRoutes 'bots-routes.bicep' = if (deployBots) {
  name: 'bots-routes-json'
  params: {
    agentNames: agentNames
    proxyAppIds: [for n in agentNames: agentAppRegs[n]]
    directAppIds: [for (n, i) in agentNames: teamsAgents[i].outputs.agentIdentityAppId]
  }
}

module teamsProxy '../modules/aca/container-app.bicep' = if (deployBots) {
  name: 'teams-proxy'
  params: {
    location: location
    tags: tags
    name: 'teams-proxy-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    definition: {
      settings: [
        {
          name: 'Foundry__ProjectEndpoint'
          value: 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${projectNames[0]}'
        }
        { name: 'Cosmos__Endpoint', value: botCosmos.outputs.endpoint }
        // Compute identity. Used for IMDS-based UAMI assertions in the
        // FIC token-exchange flow (per-bot outbound BF creds) AND for
        // Cosmos / App Insights data-plane access. NOT a bot identity.
        { name: 'AZURE_CLIENT_ID', value: teamsProxyIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID }
        { name: 'MicrosoftAppTenantId', value: tenant().tenantId }
        // Route-bound auth: middleware extracts {agent} from URL path
        // /api/messages/{foundry}/{project}/{agent} and validates JWT aud
        // against this map. Issuer accepted: the customer's tenant
        // (SingleTenant bots) — both v1 and v2 forms.
        { name: 'Bots__Routes', value: botsRoutes!.outputs.json }
        // Shared backend app reg — Teams SSO + OBO target for ALL bots.
        { name: 'TeamsApp__BackendAppId',    value: teamsAppBackendId }
        { name: 'TeamsApp__IdentifierUri',   value: teamsAppIdentifierUri }
        { name: 'TeamsApp__SsoConnectionName', value: ssoConnectionName }
        // The ONE secret in the system. OBO requires a client secret.
        // Stored as a Container Apps secret — no Key Vault.
        {
          name: 'TeamsApp__BackendSecret'
          secret: true
          secretValue: teamsAppBackendSecret
        }
        // Enable AAD auth on /admin so we can drop the "Azure AI User" RBAC
        // from the UAMI: every Foundry call that backs an /admin endpoint
        // runs as the signed-in user via OBO. Reuses the same backend
        // app reg + secret as the bot OBO path.
        { name: 'AdminChatAuth__Enabled',   value: 'true' }
        { name: 'AdminChatAuth__TenantId',  value: tenant().tenantId }
        { name: 'AdminChatAuth__ClientId',  value: teamsAppBackendId }
        {
          name: 'AdminChatAuth__ClientSecret'
          secret: true
          secretValue: teamsAppBackendSecret
        }
        { name: 'AZURE_TENANT_ID',          value: tenant().tenantId }
        // Container Apps ingress terminates TLS and forwards as plain HTTP
        // on :8080. Without this, ASP.NET Core sees scheme=http and OIDC
        // builds the redirect URI as `http://<fqdn>/signin-oidc`, which
        // Entra rejects (AADSTS50011 — only the https variant is registered
        // on the backend app reg). Enabling the built-in ForwardedHeaders
        // middleware makes the app honor X-Forwarded-Proto from the ingress
        // and emit `https://...` in redirect URIs.
        { name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED', value: 'true' }
      ]
    }
    ingressTargetPort: 8080
    existingImage: 'ghcr.io/karpikpl/foundry-teams-bot-service-proxy:0.12.1'
    userAssignedManagedIdentityClientId: teamsProxyIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: teamsProxyIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: true
    cpu: '0.25'
    memory: '0.5Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    containerAppsEnvironmentResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 8080
        }
      }
    ]
  }
}

// Proxy bot — one per agent. msaAppId = the agent's dedicated app reg
// (SingleTenant, FIC-based outbound BF auth). The ABS OAuth connection on
// each bot points at the SAME app reg as the bot identity — that's the
// per-agent SSO target, with identifierUri `api://botid-<thisAppId>` so
// Teams' silent SSO resource-match check passes for THIS bot. Each bot
// has its own client secret used for OBO.
module botServicesForProxy '../modules/bot/bot-service.bicep' = [for (agentName, i) in agentNames: if (deployBots) {
  name: 'bot-proxy-${agentName}-${resourceToken}'
  params: {
    tags: tags
    location: 'global'
    name: 'bot-proxy-${agentName}-${resourceToken}'
    displayName: agentName
    sku: 'F0'
    endpoint: '${teamsProxy!.outputs.CONTAINER_APP_FQDN}/api/messages/${foundry.outputs.FOUNDRY_NAME}/${projectNames[0]}/${agentName}'
    disableLocalAuth: false
    msaAppType: 'SingleTenant'
    msaAppId: agentAppRegs[agentName]
    enableTeamsChannel: true
    enableDirectLineChannel: true
    appInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    // Per-agent SSO: each bot's OAuth connection points at the bot's OWN
    // app reg. tokenExchangeUrl uses the `api://botid-<botId>` form so Teams'
    // resource-match check passes. clientSecret comes from the per-agent
    // entry in the secure agentAppSecrets map.
    ssoConnectionName: ssoConnectionName
    ssoClientId: agentAppRegs[agentName]
    ssoClientSecret: agentAppSecrets[agentName]
    ssoTokenExchangeUrl: 'api://botid-${agentAppRegs[agentName]}'
  }
  dependsOn: [
    projects
  ]
}]

// ---------------------------------------------------------------------------
// Teams app manifests — 2 per agent (direct + proxy). Each entry contains
// both manifests for one agent so publish-teams-agent can build two .zip
// files per agent. Both share webApplicationInfo.id = teamsAppBackendId so
// all bots use the SAME silent SSO target.
//
// Emitted as a typed object array output (NOT a var) because each manifest
// references runtime outputs from teamsAgents[i] — Bicep `var`s can only
// contain values known at deployment start.
// ---------------------------------------------------------------------------
// Move manifests to the output section (for-expressions with runtime values
// are permitted in outputs). See `output TEAMS_MANIFESTS array` below.

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = projectNames
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output FOUNDRY_RESOURCE_GROUP string = resourceGroup().name
output PROJECT_NAME string = projectNames[0]
output LOCATION string = location
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = 'gpt-5.2'
output OPENAPI_URL string = first(filter(apiServices, api => api.name == 'weather-openapi')).?uri ?? ''

// Multi-agent outputs (consumed by postprovision-multi-agent + publish-teams-agent)
output AGENT_NAMES string[] = agentNames
output DEPLOY_BOTS bool = deployBots
output TEAMS_APP_BACKEND_ID string = teamsAppBackendId
output TEAMS_APP_IDENTIFIER_URI string = teamsAppIdentifierUri
output SSO_CONNECTION_NAME string = ssoConnectionName

// UAMI principalId — postprovision uses this as the FIC subject when
// creating federated credentials on each agent app reg.
output TEAMS_PROXY_IDENTITY_PRINCIPAL_ID string = teamsProxyIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
output TEAMS_PROXY_IDENTITY_CLIENT_ID string = teamsProxyIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
output TEAMS_PROXY_IDENTITY_RESOURCE_ID string = teamsProxyIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID

// Each entry: { agentName, direct: <manifest>, proxy: <manifest> }
// publish-teams-agent reads this output and writes 2 .zip files per entry.
output TEAMS_MANIFESTS array = [for (agentName, i) in agentNames: {
  agentName: agentName
  direct: {
    '$schema': 'https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json'
    manifestVersion: '1.22'
    version: '1.0.0'
    id: teamsAgents[i].outputs.agentIdentityAppId
    developer: {
      name: 'AI Foundry'
      websiteUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
      privacyUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
      termsOfUseUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
    }
    name: {
      short: agentName
      full: '${agentName} (Foundry)'
    }
    description: {
      short: 'AI Foundry agent published to Microsoft Teams.'
      full: 'Conversational interface for the AI Foundry agent "${agentName}", exposed via Azure Bot Service activityprotocol.'
    }
    icons: {
      color: 'default-color-icon.png'
      outline: 'default-outline-icon.png'
    }
    accentColor: '#0078D4'
    validDomains: ['token.botframework.com']
    webApplicationInfo: {
      id: teamsAgents[i].outputs.agentIdentityAppId
      resource: 'https://ai.azure.com'
    }
    bots: [
      {
        botId: teamsAgents[i].outputs.agentIdentityAppId
        scopes: ['personal', 'team', 'groupChat', 'copilot']
        supportsFiles: true
        isNotificationOnly: false
      }
    ]
    copilotAgents: {
      customEngineAgents: [
        {
          id: teamsAgents[i].outputs.agentIdentityAppId
          type: 'bot'
          disclaimer: { text: 'This agent uses AI. Please verify important information.' }
        }
      ]
    }
  }
  proxy: {
    '$schema': 'https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json'
    manifestVersion: '1.22'
    version: '1.0.0'
    id: agentAppRegs[agentName]
    developer: {
      name: 'AI Foundry'
      websiteUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
      privacyUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
      termsOfUseUrl: 'https://learn.microsoft.com/azure/ai-foundry/'
    }
    name: {
      short: '${agentName}-proxy'
      full: '${agentName} (Foundry — proxy)'
    }
    description: {
      short: 'AI Foundry agent via proxy bot.'
      full: 'Proxy bot fronting the Foundry agent "${agentName}" with Teams SSO + OBO to Foundry.'
    }
    icons: {
      color: 'default-color-icon.png'
      outline: 'default-outline-icon.png'
    }
    accentColor: '#0078D4'
    validDomains: ['token.botframework.com']
    // Per-agent SSO: webApplicationInfo.id = botId (this agent's app reg),
    // resource = `api://botid-<botId>`. Teams enforces that the resource
    // URI encode the botId before silently issuing an SSO token for it —
    // this is the rule that broke the previous "one shared backend reg
    // for every bot" design with `resourcematchfailed`.
    webApplicationInfo: {
      id: agentAppRegs[agentName]
      resource: 'api://botid-${agentAppRegs[agentName]}'
    }
    bots: [
      {
        botId: agentAppRegs[agentName]
        scopes: ['personal', 'team', 'groupChat', 'copilot']
        supportsFiles: true
        isNotificationOnly: false
      }
    ]
    copilotAgents: {
      customEngineAgents: [
        {
          id: agentAppRegs[agentName]
          type: 'bot'
          disclaimer: { text: 'This agent uses AI. Please verify important information.' }
        }
      ]
    }
  }
}]

// Per-agent publish info (used by publish-teams-agent to call the Foundry
// /microsoft365/publish API). agentGuid + blueprintAppId come from the
// foundry-agent module's deploymentScript output.
output AGENT_PUBLISH_INFO array = [for (agentName, i) in agentNames: {
  agentName: agentName
  agentGuid: teamsAgents[i].outputs.agentGuid
  blueprintAppId: teamsAgents[i].outputs.agentBlueprintAppId
}]

// Map agentName → bot identity appIds (direct = Foundry SP appId; proxy = our app reg).
output AGENT_DIRECT_APP_IDS array = [for (agentName, i) in agentNames: {
  agentName: agentName
  appId: teamsAgents[i].outputs.agentIdentityAppId
}]
output AGENT_PROXY_APP_IDS array = [for agentName in agentNames: {
  agentName: agentName
  appId: agentAppRegs[agentName]
}]

output PROXY_FQDN string = deployBots ? teamsProxy!.outputs.CONTAINER_APP_FQDN : ''
