// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param openAiApiBase string
param openAiResourceId string
param openAiLocation string = location
param existingFoundryName string?
param projectsCount int = 3

var tags = {
  'created-by': 'option-ai-gateway'
  'hidden-title': 'Foundry - APIM v2 Basic Public'
  SecurityControl: 'Ignore'
}

var valid_config = empty(openAiApiBase) || empty(openAiResourceId)
  ? fail('OPENAI_API_BASE and OPENAI_RESOURCE_ID environment variables must be set.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var openAiParts = split(openAiResourceId, '/')
var openAiName = last(openAiParts)
var openAiSubscriptionId = openAiParts[2]
var openAiResourceGroupName = openAiParts[4]

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
    extraAgentSubnets: 1
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    #disable-next-line what-if-short-circuiting
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    #disable-next-line what-if-short-circuiting
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: '' // create AI serviced PE later
    aiAccountNameResourceGroupName: ''
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
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-kv-foundry-${resourceToken}'
    privateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.vaultcore.azure.net']!.resourceId
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
    disableLocalAuth: false // keep local auth enabled for AI Gateway integration
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
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
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
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

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundryName: foundryName
      projectId: i
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
    dependsOn: [foundry ?? fake_foundry]
  }
]

module ai_gateway '../modules/apim/ai-gateway.bicep' = {
  name: 'ai-gateway-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    resourceToken: resourceToken
    aiFoundryName: foundryName
    aiFoundryProjectNames: [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    staticModels: [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: {
            name: 'gpt-4.1-mini'
            version: '2025-01-01-preview'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'gpt-5-mini'
        properties: {
          model: {
            name: 'gpt-5-mini'
            version: '2025-04-01-preview'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'o3-mini'
        properties: {
          model: {
            name: 'o3-mini'
            version: '2025-01-01-preview'
            format: 'OpenAI'
          }
        }
      }
    ]
    aiServicesConfig: [
      {
        name: openAiName
        resourceId: openAiResourceId
        endpoint: openAiApiBase
        location: openAiLocation
      }
    ]
  }
  dependsOn: [foundry ?? fake_foundry]
}

module apim_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: 'apim-role-assignment-deployment-${resourceToken}'
  scope: resourceGroup(openAiSubscriptionId, openAiResourceGroupName)
  params: {
    accountName: openAiName
    projectPrincipalId: ai_gateway.outputs.apimPrincipalId
    roleName: 'Cognitive Services User'
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

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output FOUNDRY_PROJECT_NAMES string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output CONFIG_VALIDATION_RESULT bool = valid_config
output FOUNDRY_NAME string = foundryName
