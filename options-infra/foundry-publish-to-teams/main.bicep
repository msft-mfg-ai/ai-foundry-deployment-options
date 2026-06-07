// foundry-publish-to-teams
// ============================================================================
// Publishes an EXISTING Foundry agent to Microsoft Teams via Azure Bot Service.
//
// Inputs: existing Foundry account, project, and agent name (all in this
// resource group). The agent must already be created (Foundry portal, the
// `foundry-agent.bicep` module, the SDK, …).
//
// What this deploys:
//   1. enable-agent-activity-protocol  — PATCHes the agent endpoint to add
//      `activity` to protocols and `BotServiceRbac` to authorization schemes
//      so Bot Service tokens are accepted by Foundry. Returns the agent's
//      ServiceIdentity appId / blueprint appId / agent_guid for downstream
//      wiring.
//   2. bot-service                     — Azure Bot Service (SKU = S1, MUST
//      be Standard for the Teams channel to actually deliver traffic — F0
//      silently drops Teams events) with msaAppId = the agent's
//      instance_identity.client_id. WebChat + DirectLine + Teams channels
//      are enabled.
//   3. Teams app manifest              — emitted as the `TEAMS_MANIFEST_JSON`
//      output; the postprovision hook (`azure.yaml`) zips it with the icons
//      in ./teams-app/ for sideloading.
//
// The actual Microsoft 365 publish call also happens in postprovision because
// the `/microsoft365/publish` data-plane API requires a user-delegated token
// (calling it from a deploymentScript's UAMI returns "Underlying error while
// obtaining user token"). See the project README for the full flow.
// ============================================================================

targetScope = 'resourceGroup'

@description('Existing Foundry (Cognitive Services) account name.')
param aiFoundryName string

@description('Resource group containing the Foundry account. Leave empty to use the deployment RG; set when the Foundry account lives in a different RG.')
param aiFoundryResourceGroupName string = ''

@description('Existing Foundry project name under the account.')
param aiFoundryProjectName string

@description('Existing agent name in the project. Must already be created (this option does NOT create the agent).')
@maxLength(63)
param agentName string

@description('Display name shown in Teams app catalog and channels. Defaults to the agent name.')
param agentDisplayName string = agentName

@description('Short description shown in the Teams app card. ≤80 chars.')
@maxLength(80)
param agentShortDescription string = '${agentName} (Foundry)'

@description('Full description shown in the Teams app card. ≤4000 chars.')
@maxLength(4000)
param agentFullDescription string = 'AI Foundry agent ${agentName} surfaced in Microsoft Teams via Azure Bot Service.'

@description('Developer/publisher metadata for the Teams manifest.')
param developerName string = 'AI Foundry'

@description('Developer website URL shown in the Teams app card.')
param developerWebsiteUrl string = 'https://learn.microsoft.com/azure/ai-foundry/'

@description('Privacy policy URL.')
param privacyUrl string = 'https://learn.microsoft.com/azure/ai-foundry/'

@description('Terms-of-use URL.')
param termsOfUseUrl string = 'https://learn.microsoft.com/azure/ai-foundry/'

param location string = resourceGroup().location

var tags = {
  'created-by': 'foundry-publish-to-teams'
  'hidden-title': 'Foundry → Teams publisher'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location, agentName))

// ---------------------------------------------------------------------------
// 1. Enable activityprotocol + BotServiceRbac on the existing agent
// ---------------------------------------------------------------------------
var foundryRg = empty(aiFoundryResourceGroupName) ? resourceGroup().name : aiFoundryResourceGroupName

module enableActivity '../modules/ai/foundry-agent.bicep' = {
  // Deployment names cap at 64 chars; agentName can be up to 63 so we don't
  // include it here. The token+suffix is unique within the RG already.
  name: 'enable-activity-${resourceToken}'
  params: {
    tags: tags
    location: location
    aiFoundryName: aiFoundryName
    aiFoundryResourceGroupName: foundryRg
    aiFoundryProjectName: aiFoundryProjectName
    agentName: agentName
    // Existing agent — do NOT create. The module always runs the PATCH
    // for activityprotocol + BotServiceRbac (required for Teams).
    createAgent: false
    resourceSuffix: resourceToken
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
// 2. Azure Bot Service wired to the agent's activityprotocol endpoint
// ---------------------------------------------------------------------------
// Bot Service resource names are limited to 42 chars. We truncate the
// (lowercased, sanitized) agent name to leave room for the prefix + token.
var botNameSafe = take(toLower(replace(replace(agentName, '_', '-'), '.', '-')), 25)
var botResourceName = take('bot-${botNameSafe}-${resourceToken}', 42)

module botService '../modules/bot/bot-service.bicep' = {
  name: 'bot-service-${resourceToken}'
  params: {
    tags: tags
    location: 'global'
    name: botResourceName
    displayName: agentDisplayName
    // SKU MUST be S1 (Standard) for the Microsoft Teams channel to deliver
    // traffic. On F0 (Free) the channel shows as enabled but Teams events
    // never reach the bot.
    sku: 'S1'
    endpoint: 'https://${aiFoundryName}.services.ai.azure.com/api/projects/${aiFoundryProjectName}/agents/${agentName}/endpoint/protocols/activityprotocol?api-version=2025-11-15-preview'
    disableLocalAuth: false
    // Use the agent's auto-created ServiceIdentity SP appId as msaAppId.
    // BF channels mint tokens with aud = msaAppId; Foundry's activityprotocol
    // (with the BotServiceRbac auth scheme enabled by `enableActivity` above)
    // validates aud against the same appId, so they match.
    msaAppType: 'SingleTenant'
    msaAppId: enableActivity.outputs.agentIdentityAppId
    enableTeamsChannel: true
    enableDirectLineChannel: true
    appInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
  }
}


// ---------------------------------------------------------------------------
// 3. Teams app manifest — emitted as a string output; the postprovision hook
//    zips it with the icons in ./teams-app/.
// ---------------------------------------------------------------------------
var teamsAppId = guid(resourceGroup().id, 'teams-app', agentName)

var teamsManifest = {
  '$schema': 'https://developer.microsoft.com/json-schemas/teams/v1.22/MicrosoftTeams.schema.json'
  manifestVersion: '1.22'
  version: '1.0.0'
  id: teamsAppId
  developer: {
    name: developerName
    websiteUrl: developerWebsiteUrl
    privacyUrl: privacyUrl
    termsOfUseUrl: termsOfUseUrl
  }
  name: {
    short: take(agentDisplayName, 30)
    full: take('${agentDisplayName} (Foundry)', 100)
  }
  description: {
    short: agentShortDescription
    full: agentFullDescription
  }
  icons: {
    color: 'default-color-icon.png'
    outline: 'default-outline-icon.png'
  }
  accentColor: '#0078D4'
  validDomains: []
  bots: [
    {
      botId: enableActivity.outputs.agentIdentityAppId
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
        id: enableActivity.outputs.agentIdentityAppId
        type: 'bot'
        disclaimer: {
          text: 'This agent uses AI. Please verify important information.'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs — consumed by azure.yaml postprovision hook + by humans
// ---------------------------------------------------------------------------
output FOUNDRY_NAME string = aiFoundryName
output FOUNDRY_RESOURCE_GROUP string = foundryRg
output PROJECT_NAME string = aiFoundryProjectName
output AGENT_NAME string = agentName
output LOCATION string = location

output BOT_RESOURCE_ID string = botService.outputs.botResourceId
output BOT_NAME string = botService.outputs.botName
output BOT_APP_ID string = enableActivity.outputs.agentIdentityAppId

output AGENT_ID string = enableActivity.outputs.agentId
output AGENT_VERSION string = enableActivity.outputs.agentVersion
output AGENT_GUID string = enableActivity.outputs.agentGuid
output AGENT_IDENTITY_APP_ID string = enableActivity.outputs.agentIdentityAppId
output AGENT_IDENTITY_OBJECT_ID string = enableActivity.outputs.agentIdentityObjectId
output AGENT_BLUEPRINT_APP_ID string = enableActivity.outputs.agentBlueprintAppId
output AGENT_BLUEPRINT_OBJECT_ID string = enableActivity.outputs.agentBlueprintObjectId

output TEAMS_APP_ID string = teamsAppId
output TEAMS_MANIFEST_JSON string = string(teamsManifest)
