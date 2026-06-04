// foundry-byo-vnet-teams
// ============================================================================
// BYO VNet deployment with agents published to teams

targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'

param location string = resourceGroup().location
param projectsCount int = 1
param apiServices apiType[] = [] // External MCP/OpenAPI services

// ---------------------------------------------------------------------------
// Teams SSO (optional) — supplied by the `preprovision` hook in azure.yaml
// after it creates a dedicated AAD app for the proxy bot. When `ssoAppId` is
// empty the proxy still works, but only with system-managed auth (no
// on-behalf-of token flow to Foundry).
// ---------------------------------------------------------------------------
@description('Client id of the AAD app created by the preprovision script for Teams SSO. Empty disables SSO. The SSO app is assumed to live in the deployment tenant.')
param ssoAppId string = ''

@secure()
@description('Client secret of the SSO AAD app. Required when `ssoAppId` is set.')
param ssoAppSecret string = ''

var enableSso = !empty(ssoAppId) && !empty(ssoAppSecret)
var ssoConnectionName = 'foundry-sso'

// Teams Bot SSO requires the AAD app's identifierUri (and the OAuthCard's
// tokenExchangeResource.Uri) to follow `api://botid-<aad-app-id>` per
// https://learn.microsoft.com/microsoftteams/platform/bots/how-to/authentication/bot-sso-register-aad.
// In the Teams docs, {YourBotId} is the Microsoft Entra application ID that
// owns the SSO scope, which is the SSO AAD app id created by preprovision.
var ssoTokenExchangeResource = enableSso ? 'api://botid-${ssoAppId}' : ''

var tags = {
  'created-by': 'foundry-byo-vnet-teams'
  'hidden-title': 'Foundry Standard - BYO VNet + Teams Agents'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// 2. VNet — uses the shared vnet.bicep module with optional firewall subnet
//    + route table params (added by this change). All other subnets and NSGs
//    come from the module's defaults; subnet prefixes for the firewall are
//    auto-computed by vnet.bicep to avoid overlap with the standard subnets.
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
  }
}

// 3. Log Analytics workspace — created BEFORE the firewall so its workspace
//    ID can be wired into the firewall's diagnostic settings. Without this,
//    Azure Firewall emits no logs by default.
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
// Foundry stack — unchanged from foundry-two-projects.
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

var agentName = 'Teams-Agent'

// ---------------------------------------------------------------------------
// Foundry agent — created by Bicep so we can read its ServiceIdentity SP
// appId from the response and bake it into the bot service / Teams manifest.
// Also enables activityprotocol + BotServiceRbac so Bot Service traffic is
// accepted by the agent.
// ---------------------------------------------------------------------------
module teamsAgent '../modules/ai/foundry-agent.bicep' = {
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
}

module botService '../modules/bot/bot-service.bicep' = {
  name: 'bot-service-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'bot-service-${resourceToken}'
    displayName: agentName
    endpoint: 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${projectNames[0]}/agents/${agentName}/endpoint/protocols/activityprotocol?api-version=2025-11-15-preview'
    disableLocalAuth: false
    // Use the agent's auto-created ServiceIdentity SP appId as msaAppId.
    // BF channels mint tokens with aud = msaAppId; Foundry's activityprotocol
    // validates aud against this same appId, so they match without any extra
    // configuration (no UAMI, no role assignment, no Graph lookup).
    msaAppType: 'SingleTenant'
    msaAppId: teamsAgent.outputs.agentIdentityAppId
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
  }
}

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

// Single UAMI shared by the proxy container AND every bot service
// registration that targets it. Bot Framework's default JWT validator
// compares the inbound token's `appid` to the container's MicrosoftAppId
// and uses the same UAMI (via IMDS) to mint outbound replies — so the
// container identity and the bot identity must be one and the same.
module botSharedIdentity '../modules/iam/identity.bicep' = {
  name: 'bot-shared-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'bot-shared-identity-${resourceToken}'
  }
}

module foundryRoleAssignment '../modules/iam/role-assignment-foundryProject.bicep' = {
  name: 'ra-foundry-${resourceToken}'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectName: projectNames[0]
    principalId: botSharedIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    roleName: 'Azure AI User'
    servicePrincipalType: 'ServicePrincipal'
  }
  dependsOn: [
    projects
  ]
}

module botCosmos '../modules/db/cosmos.bicep' = {
  name: 'bot-cosmosdb'
  params: {
    location: location
    tags: tags
    accountName: 'bot-cosmosdb-${resourceToken}'
    appPrincipalId: botSharedIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    cosmosDbPrivateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.documents.azure.com'].resourceId
  }
}

module teamsProxy '../modules/aca/container-app.bicep' = {
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
        { name: 'MicrosoftAppId', value: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID }
        { name: 'MicrosoftAppType', value: 'UserAssignedMSI' }
        { name: 'MicrosoftAppTenantId', value: tenant().tenantId }
        { name: 'BOTSERVICE_UAMI_CLIENTID', value: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID }
        // Teams SSO — the C# proxy enables OBO when ConnectionName is set.
        { name: 'TeamsSso__ConnectionName', value: enableSso ? ssoConnectionName : '' }
        // AadAppId + Resource are required by the manifest builder to emit
        // webApplicationInfo. Without them Teams silent SSO returns
        // resourcematchfailed because the manifest has nothing to match.
        { name: 'TeamsSso__AadAppId', value: enableSso ? ssoAppId : '' }
        { name: 'TeamsSso__Resource', value: ssoTokenExchangeResource }
        // Inline Container Apps secret — only referenced when SSO is enabled.
        // Stored as a Container App secret rather than a plain env value.
        ...(enableSso ? [{
          name: 'TeamsSso__ClientSecret'
          secret: true
          secretValue: ssoAppSecret
        }] : [])
      ]
    }
    ingressTargetPort: 8080
    existingImage: 'ghcr.io/karpikpl/foundry-teams-bot-service-proxy:0.7.0'
    userAssignedManagedIdentityClientId: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: botSharedIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
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

module botServiceForProxy '../modules/bot/bot-service.bicep' = {
  name: 'bot-service-proxy--${resourceToken}'
  params: {
    tags: tags
    location: 'global'
    name: 'bot-service-proxy-${resourceToken}'
    displayName: agentName
    sku: 'F0'
    endpoint: '${teamsProxy.outputs.CONTAINER_APP_FQDN}/api/messages/${foundry.outputs.FOUNDRY_NAME}/${projectNames[0]}/${agentName}'
    disableLocalAuth: false
    // Shared UAMI: every bot service that targets teamsProxy mints tokens with
    // aud = botSharedIdentity.clientId, matching the proxy's BOTSERVICE_UAMI_CLIENTID.
    msaAppType: 'UserAssignedMSI'
    existingMsiResourceId: botSharedIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    existingMsiClientId:   botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    enableTeamsChannel: true
    enableDirectLineChannel: true
    appInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    // SSO OAuth connection — created only when the preprovision script
    // populated an SSO AAD app. The C# proxy reads the connection name and
    // exchanges the user token for a Foundry data-plane token via Bot Service.
    ssoConnectionName: enableSso ? ssoConnectionName : ''
    ssoClientId:       ssoAppId
    ssoClientSecret:   ssoAppSecret
    ssoTokenExchangeUrl: ssoTokenExchangeResource
  }
  dependsOn: [
    projects
  ]
}

// ---------------------------------------------------------------------------
// Teams app manifest
// ---------------------------------------------------------------------------
// The manifest is built here in Bicep so that botId / appId stay in sync
// with the bot service. The postprovision hook (azure.yaml) reads the
// TEAMS_MANIFEST_JSON output, drops it next to color.png/outline.png in
// ./teams-app/, and zips the result into ./teams-app/build/teams-app.zip
// which can be sideloaded into Teams.
//

var teamsManifest = {
  '$schema': 'https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json'
  manifestVersion: '1.22'
  version: '1.0.0'
  id: teamsAgent.outputs.agentIdentityAppId
  //packageName: 'com.microsoft.foundry.${teamsAgentNameSanitized}'
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
    full: 'Conversational interface for the AI Foundry agent "${agentName}", exposed via Azure Bot Service.'
  }
  icons: {
    color: 'default-color-icon.png'
    outline: 'default-outline-icon.png'
  }
  accentColor: '#0078D4'
  validDomains: [
    'token.botframework.com'
  ]
  webApplicationInfo: {
    id: teamsAgent.outputs.agentIdentityAppId
    resource: 'https://ai.azure.com'
  }
  bots: [
    {
      botId: teamsAgent.outputs.agentIdentityAppId
      scopes: [
        'personal'
        'team'
        'groupChat'
        'copilot'
      ]
      supportsFiles: true
      isNotificationOnly: false
    }
  ]
  copilotAgents: {
    customEngineAgents: [
      {
        id: teamsAgent.outputs.agentIdentityAppId
        type: 'bot'
        disclaimer: {
          text: 'This agent uses AI. Please verify important information.'
        }
      }
    ]
  }
}

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
output botResourceId string = botService.outputs.botResourceId
output botName string = botService.outputs.botName
output BOT_APP_ID string = teamsAgent.outputs.agentIdentityAppId
output AGENT_NAME string = agentName
output AGENT_ID string = teamsAgent.outputs.agentId
output AGENT_VERSION string = teamsAgent.outputs.agentVersion
output AGENT_GUID string = teamsAgent.outputs.agentGuid
output AGENT_IDENTITY_APP_ID string = teamsAgent.outputs.agentIdentityAppId
output AGENT_IDENTITY_OBJECT_ID string = teamsAgent.outputs.agentIdentityObjectId
output AGENT_BLUEPRINT_APP_ID string = teamsAgent.outputs.agentBlueprintAppId
output AGENT_BLUEPRINT_OBJECT_ID string = teamsAgent.outputs.agentBlueprintObjectId
output TEAMS_APP_ID string = teamsAgent.outputs.agentIdentityAppId
output TEAMS_MANIFEST_JSON string = string(teamsManifest)

// ---------------------------------------------------------------------------
// Second Teams manifest — for the proxy bot (botServiceForProxy).
// Same shape as the agent manifest, but pointed at the shared bot UAMI
// (which is the proxy bot's `msaAppId`) and, when SSO is enabled, advertises
// the SSO AAD app via `webApplicationInfo` so Teams will request a token
// from `api://<ssoAppId>` and forward it to the bot.
// ---------------------------------------------------------------------------
var teamsManifestProxy = {
  '$schema': 'https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json'
  manifestVersion: '1.22'
  version: '1.0.0'
  id: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
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
    full: 'Proxy bot fronting the Foundry agent "${agentName}" with optional Teams SSO.'
  }
  icons: {
    color: 'default-color-icon.png'
    outline: 'default-outline-icon.png'
  }
  accentColor: '#0078D4'
  validDomains: [
    'token.botframework.com'
  ]
  webApplicationInfo: enableSso ? {
    id: ssoAppId
    resource: ssoTokenExchangeResource
  } : {
    id: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    resource: 'https://ai.azure.com'
  }
  bots: [
    {
      botId: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
      scopes: [
        'personal'
        'team'
        'groupChat'
        'copilot'
      ]
      supportsFiles: true
      isNotificationOnly: false
    }
  ]
  copilotAgents: {
    customEngineAgents: [
      {
        id: botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
        type: 'bot'
        disclaimer: {
          text: 'This agent uses AI. Please verify important information.'
        }
      }
    ]
  }
}

output TEAMS_MANIFEST_PROXY_JSON string = string(teamsManifestProxy)
output SSO_CONNECTION_NAME string = enableSso ? ssoConnectionName : ''
output SSO_APP_ID string = ssoAppId
output PROXY_BOT_APP_ID string = botSharedIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
output PROXY_BOT_NAME string = botServiceForProxy.outputs.botName
