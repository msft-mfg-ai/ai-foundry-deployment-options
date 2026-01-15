// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
@secure()
param openRouterApiKey string
param existingFoundryName string?
param projectsCount int = 3

var tags = {
  'created-by': 'option-ai-gateway'
  'hidden-title': 'Foundry - OpenRouter'
}

var valid_config = empty(openRouterApiKey) ? fail('OPENROUTER_API_KEY environment variable must be set.') : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics Workspace and App Insights ------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

module keyVault '../modules/kv/key-vault.bicep' = {
  name: 'key-vault-deployment-for-foundry'
  params: {
    tags: tags
    location: location
    name: take('kv-foundry-${resourceToken}', 24)
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    doRoleAssignments: true
    secrets: []
    publicAccessEnabled: false
    privateEndpointSubnetId: null
    privateEndpointName: null
    privateDnsZoneResourceId: null
  }
}

var foundryName = existingFoundryName ?? 'ai-foundry-${resourceToken}'

module foundry '../modules/ai/ai-foundry.bicep' = if (empty(existingFoundryName)) {
  name: 'foundry-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    #disable-next-line what-if-short-circuiting
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: foundryName
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: null
    deployments: [] // no models
    #disable-next-line what-if-short-circuiting
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
    keyVaultConnectionEnabled: true
    existing_Foundry_Name: existingFoundryName
  }
}

// This is required due to KeyVault issue resulting in Foundry deployment timeout
// https://portal.microsofticm.com/imp/v5/incidents/details/21000000774829/summary - AKV Detach Bug
// https://msdata.visualstudio.com/Vienna/_workitems/edit/4814146/
module fake_foundry '../modules/ai/ai-foundry-fake.bicep' = if (!empty(existingFoundryName)) {
  name: 'fake-foundry-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    managedIdentityId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: foundryName
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: null
    deployments: [] // no models
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
    keyVaultConnectionEnabled: true
    existing_Foundry_Name: existingFoundryName
  }
}

module identities '../modules/iam/identity.bicep' = [
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
module projects '../modules/ai/ai-project.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundry_name: foundryName
      project_name: projectNames[i - 1]
      display_name: 'AI Project ${i}'
      project_description: 'AI Project ${i} deployed via AI Gateway OpenRouter option'
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
      createAccountCapabilityHost: true
    }
    dependsOn: [foundry ?? fake_foundry]
  }
]

module modelGatewayConnectionStatic '../modules/ai/connection-modelgateway-static.bicep' = [
  for projectName in projectNames: {
    name: '${projectName}-connection-gateway'
    params: {
      aiFoundryName: foundryName
      aiFoundryProjectName: projectName
      connectionName: 'openrouter-gateway-${projectName}-static'
      apiKey: openRouterApiKey
      isSharedToAll: false
      gatewayName: 'apim'
      // Static model list - aliases map to actual OpenRouter model IDs
      // Aliases must NOT contain slashes to avoid path conflicts
      staticModels: [
        {
          name: 'gpt-4o-mini'
          properties: {
            model: {
              name: 'openai/gpt-4o-mini' // Actual OpenRouter model ID
              version: ''
              format: 'OpenAI'
            }
          }
        }
        {
          name: 'gpt-4.1-mini'
          properties: {
            model: {
              name: 'moonshotai/kimi-k2:free' // Actual OpenRouter model ID
              version: ''
              format: 'OpenAI'
            }
          }
        }
        {
          name: 'qwen3-4b'
          properties: {
            model: {
              name: 'qwen/qwen3-4b:free' // Actual OpenRouter model ID
              version: ''
              format: 'OpenAI'
            }
          }
        }
      ]
      // No api-version query parameter needed
      inferenceAPIVersion: ''
      targetUrl: 'https://openrouter.ai/api/v1'
      // OpenRouter uses model name in body, not path
      deploymentInPath: 'false'
      authType: 'ApiKey'
      authConfig: {
        type: 'api_key'
        name: 'Authorization'
        format: 'Bearer {api_key}'
      }
    }
    dependsOn: [foundry ?? fake_foundry, projects]
  }
]

module models_policy '../modules/policy/models-policy.bicep' = {
  scope: subscription()
  name: 'policy-definition-deployment-${resourceToken}'
}

module models_policy_assignment '../modules/policy/models-policy-assignment.bicep' = {
  name: 'policy-assignment-deployment-${resourceToken}'
  params: {
    cognitiveServicesPolicyDefinitionId: models_policy.outputs.cognitiveServicesPolicyDefinitionId
    allowedCognitiveServicesModels: []
  }
}

module dashboard_setup '../modules/dashboard/dashboard-setup.bicep' = {
  name: 'dashboard-setup-deployment-${resourceToken}'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_NAME
    dashboardDisplayName: 'APIM Token Usage Dashboard for ${resourceToken}'
  }
}

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output FOUNDRY_PROJECT_NAMES string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output CONFIG_VALIDATION_RESULT bool = valid_config
output FOUNDRY_NAME string = foundryName
