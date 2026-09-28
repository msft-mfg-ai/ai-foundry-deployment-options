targetScope = 'resourceGroup'

@description('Existing API Management service name.')
param apimName string

@description('Foundry project resource ID used for project-scoped role assignments.')
param foundryProjectId string

@description('Foundry project data-plane endpoint.')
param foundryProjectEndpoint string

@description('Hosted Teams gateway agent name.')
param agentName string

@description('Active hosted Teams gateway agent version.')
param agentVersion string

@description('Hosted Teams gateway instance identity client ID used as the Azure Bot audience.')
param botAppId string

@description('Azure Bot resource name.')
param botName string

@description('Hosted Teams gateway instance identity principal ID.')
param agentPrincipalId string

@description('Existing Cosmos DB account used for Bot Framework conversation state.')
param cosmosAccountName string

@description('Storage account used to stage generated files before Teams consent upload.')
param generatedFilesStorageAccountName string

@description('Existing APIM Foundry User role assignment name, when migrating an existing environment.')
param apimFoundryUserRoleAssignmentName string = ''

@description('Existing APIM Foundry Agent Consumer role assignment name, when migrating an existing environment.')
param apimAgentConsumerRoleAssignmentName string = ''

@description('Existing gateway Cosmos SQL role assignment name, when migrating an existing environment.')
param gatewayCosmosRoleAssignmentName string = ''

@description('Azure Bot OAuth connection name used for Teams SSO.')
param teamsSsoConnectionName string = ''

@description('Client ID of the Entra application used by the Teams SSO OAuth connection.')
param teamsSsoClientId string = ''

@secure()
@description('Client secret of the Entra application used by the Teams SSO OAuth connection.')
param teamsSsoClientSecret string = ''

@description('Space-delimited delegated scopes requested by the Teams SSO OAuth connection.')
param teamsSsoScopes string = ''

@description('Application ID URI used for Teams token exchange, for example api://botid-<app-id>.')
param teamsSsoTokenExchangeUrl string = ''

@description('Azure Bot OAuth connection that returns a user assertion audienced to the Agent Identity blueprint.')
param agentIdentitySsoConnectionName string = ''

@description('Agent Identity blueprint application ID URI.')
param agentIdentitySsoTokenExchangeUrl string = ''

@description('Agent Identity blueprint delegated scope plus offline_access.')
param agentIdentitySsoScopes string = ''

var apiId = 'teams-hosted-agents'
var backendId = 'teams-hosted-agent-invocations'
var sessionAdminApiId = 'teams-hosted-agent-sessions'
var sessionAdminSubscriptionName = 'teams-hosted-agent-sessions'
var foundryUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '53ca6127-db72-4b80-b1b0-d745d6d5456d'
)
var foundryAgentConsumerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'eed3b665-ab3a-47b6-8f48-c9382fb1dad6'
)
var projectParts = split(foundryProjectId, '/')
var foundryAccountName = projectParts[8]
var foundryProjectName = last(projectParts)
var normalizedProjectEndpoint = endsWith(foundryProjectEndpoint, '/')
  #disable-next-line BCP329
  ? substring(foundryProjectEndpoint, 0, length(foundryProjectEndpoint) - 1)
  : foundryProjectEndpoint
var botIdMap = {
  '${agentName}': botAppId
}
var agentVersionMap = {
  '${agentName}': agentVersion
}
var messagingEndpoint = '${apim.properties.gatewayUrl}/teams/${agentName}/api/messages'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-07-01-preview' existing = {
  name: foundryAccountName
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-07-01-preview' existing = {
  parent: foundryAccount
  name: foundryProjectName
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' existing = {
  name: cosmosAccountName
}

module teamsBot '../modules/bot/bot-service.bicep' = {
  name: 'teams-bot-${agentName}'
  params: {
    name: botName
    displayName: agentName
    endpoint: messagingEndpoint
    sku: 'F0'
    msaAppType: 'SingleTenant'
    msaAppId: botAppId
    enableTeamsChannel: true
    enableDirectLineChannel: false
    disableLocalAuth: true
    ssoConnectionName: teamsSsoConnectionName
    ssoClientId: teamsSsoClientId
    ssoClientSecret: teamsSsoClientSecret
    ssoScopes: teamsSsoScopes
    ssoTokenExchangeUrl: teamsSsoTokenExchangeUrl
  }
}

var enableAgentIdentitySso = !empty(agentIdentitySsoConnectionName) && !empty(agentIdentitySsoTokenExchangeUrl) && !empty(agentIdentitySsoScopes)

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' existing = {
  name: botName
}

resource agentIdentitySsoConnection 'Microsoft.BotService/botServices/connections@2023-09-15-preview' = if (enableAgentIdentitySso) {
  parent: bot
  name: agentIdentitySsoConnectionName
  location: 'global'
  properties: {
    serviceProviderId: '30dd229c-58e3-4a48-bdfd-91ec48eb906c'
    serviceProviderDisplayName: 'Azure Active Directory v2'
    clientId: teamsSsoClientId
    clientSecret: teamsSsoClientSecret
    scopes: agentIdentitySsoScopes
    parameters: [
      { key: 'tenantID', value: tenant().tenantId }
      { key: 'tokenExchangeUrl', value: agentIdentitySsoTokenExchangeUrl }
    ]
  }
  dependsOn: [
    teamsBot
  ]
}

resource backend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: backendId
  properties: {
    description: 'Foundry hosted-agent Invocations endpoint'
    protocol: 'http'
    url: normalizedProjectEndpoint
  }
}

resource botIds 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'teams-agent-bot-ids'
  properties: {
    displayName: 'teams-agent-bot-ids'
    secret: false
    value: base64(string(botIdMap))
  }
}

resource agentVersions 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'teams-agent-versions'
  properties: {
    displayName: 'teams-agent-versions'
    secret: false
    value: base64(string(agentVersionMap))
  }
}

resource projectEndpoint 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'teams-foundry-project-endpoint'
  properties: {
    displayName: 'teams-foundry-project-endpoint'
    secret: false
    value: normalizedProjectEndpoint
  }
}

resource api 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: apiId
  properties: {
    apiType: 'http'
    displayName: 'Teams hosted agents'
    path: 'teams'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

resource messagesOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: api
  name: 'messages'
  properties: {
    displayName: 'Bot messages'
    method: 'POST'
    urlTemplate: '/{agent-name}/api/messages'
    templateParameters: [
      {
        name: 'agent-name'
        type: 'string'
        required: true
        values: []
      }
    ]
    responses: []
  }
}

resource messagesPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: messagesOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('apim/bot-invocations-policy.xml')
  }
  dependsOn: [
    backend
    botIds
    agentVersions
    projectEndpoint
  ]
}

resource sessionAdminApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: sessionAdminApiId
  properties: {
    apiType: 'http'
    displayName: 'Teams hosted-agent session administration'
    description: 'Subscription-protected access to inspect or remove a version-bound hosted session.'
    path: 'teams-admin'
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    type: 'http'
  }
}

resource getSessionOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: sessionAdminApi
  name: 'get-session'
  properties: {
    displayName: 'Get current hosted session'
    method: 'GET'
    urlTemplate: '/{agent-name}/sessions/current'
    templateParameters: [
      {
        name: 'agent-name'
        type: 'string'
        required: true
        values: []
      }
    ]
    responses: []
  }
}

resource deleteSessionOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: sessionAdminApi
  name: 'delete-session'
  properties: {
    displayName: 'Delete current hosted session'
    method: 'DELETE'
    urlTemplate: '/{agent-name}/sessions/current'
    templateParameters: [
      {
        name: 'agent-name'
        type: 'string'
        required: true
        values: []
      }
    ]
    responses: []
  }
}

resource sessionAdminPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: sessionAdminApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('apim/session-admin-policy.xml')
  }
  dependsOn: [
    agentVersions
  ]
}

resource sessionAdminSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: sessionAdminSubscriptionName
  properties: {
    displayName: 'Teams hosted-agent session administration'
    scope: '/apis/${sessionAdminApiId}'
    state: 'active'
  }
  dependsOn: [
    sessionAdminApi
  ]
}

resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2022-08-01' = {
  parent: api
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    logClientIp: true
    loggerId: '${apim.id}/loggers/appinsights-logger'
    metrics: true
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [
          'Content-Type'
          'User-Agent'
          'traceparent'
          'x-ms-client-request-id'
        ]
        body: {
          bytes: 8192
        }
      }
      response: {
        headers: [
          'Content-Type'
          'traceparent'
          'apim-request-id'
        ]
        body: {
          bytes: 8192
        }
      }
    }
    backend: {
      request: {
        headers: [
          'Content-Type'
          'traceparent'
          'x-ms-client-request-id'
        ]
        body: {
          bytes: 8192
        }
      }
      response: {
        headers: [
          'Content-Type'
          'traceparent'
          'apim-request-id'
        ]
        body: {
          bytes: 8192
        }
      }
    }
  }
}

resource apimFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryProject
  name: empty(apimFoundryUserRoleAssignmentName)
    ? guid(apim.id, foundryUserRoleId, foundryProject.id)
    : apimFoundryUserRoleAssignmentName
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: foundryUserRoleId
  }
}

resource apimAgentConsumer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryProject
  name: empty(apimAgentConsumerRoleAssignmentName)
    ? guid(apim.id, foundryAgentConsumerRoleId, foundryProject.id)
    : apimAgentConsumerRoleAssignmentName
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: foundryAgentConsumerRoleId
  }
}

resource hostedAgentFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundryProject
  name: guid(agentPrincipalId, foundryUserRoleId, foundryProject.id)
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: foundryUserRoleId
  }
}

resource generatedFilesStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: generatedFilesStorageAccountName
}

var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource hostedAgentGeneratedFilesContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: generatedFilesStorageAccount
  name: guid(
    agentPrincipalId,
    storageBlobDataContributorRoleId,
    generatedFilesStorageAccount.id
  )
  properties: {
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

var cosmosDataContributorRoleId = resourceId(
  'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
  cosmosAccountName,
  '00000000-0000-0000-0000-000000000002'
)

resource gatewayCosmosDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2022-05-15' = {
  parent: cosmosAccount
  name: empty(gatewayCosmosRoleAssignmentName)
    ? guid(cosmosAccount.id, agentPrincipalId, cosmosDataContributorRoleId)
    : gatewayCosmosRoleAssignmentName
  properties: {
    principalId: agentPrincipalId
    roleDefinitionId: cosmosDataContributorRoleId
    scope: cosmosAccount.id
  }
}

output apiResourceId string = api.id
output backendResourceId string = backend.id
output botName string = teamsBot.outputs.botName
output botAppId string = botAppId
output messagingEndpoint string = messagingEndpoint
output sessionAdminEndpoint string = '${apim.properties.gatewayUrl}/teams-admin/${agentName}/sessions/current'
output sessionAdminSubscriptionResourceName string = sessionAdminSubscription.name
