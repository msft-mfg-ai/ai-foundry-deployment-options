// Deploys Azure AI Foundry with an APIM AI Gateway configured to proxy Claude (Anthropic)
// models hosted on a Foundry account. Designed for scenarios where the Anthropic Foundry
// account is in a different tenant — authentication uses an API key sent as a backend
// credential header rather than managed identity.
//
// Infrastructure deployed:
//  - VNet + private DNS zones
//  - Foundry account + projects with capability hosts
//  - Key Vault, Log Analytics, App Insights
//  - APIM Standardv2 (External VNet) with private endpoint
//  - Anthropic inference API at {gateway}/inference/anthropic
//  - Foundry connections (static model list, deploymentInPath=false)

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Base endpoint of the Foundry account hosting Claude models (e.g. https://<name>.services.ai.azure.com).')
param anthropicApiBase string

@description('API key for the Anthropic Foundry endpoint.')
@secure()
param anthropicApiKey string

@description('Resource ID of the Foundry account hosting Claude models. Used as backend metadata only; not required for auth.')
param anthropicResourceId string = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/placeholder/providers/Microsoft.CognitiveServices/accounts/placeholder'

@description('Location of the Foundry account hosting Claude models.')
param anthropicLocation string = location

@description('Number of Foundry projects to create.')
param projectsCount int = 1

@description('Allow public access to APIM. Set to true for testing; false for production.')
param apimPublicEnabled bool = true

@description('Static list of Claude model deployments to surface in Foundry connections.')
param staticModels object[] = [
  {
    name: 'claude-opus-4-6'
    properties: {
      model: {
        name: 'claude-opus-4-6'
        version: '20250514'
        format: 'Anthropic'
      }
    }
  }
]

var tags = {
  'created-by': 'option-ai-gateway-anthropic'
  'hidden-title': 'Foundry - Anthropic AI Gateway (APIM v2 Standard with PE)'
  SecurityControl: 'Ignore'
}

var valid_anthropic_config = empty(anthropicApiBase) || empty(anthropicApiKey)
  ? fail('ANTHROPIC_API_BASE and ANTHROPIC_API_KEY environment variables must be set.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var anthropicServicesConfig = [
  {
    name: 'anthropic-foundry'
    resourceId: anthropicResourceId
    endpoint: anthropicApiBase
    location: anthropicLocation
  }
]

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
    extraAgentSubnets: 1
    vnetAddressPrefix: '192.168.0.0/20'
  }
}

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

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: []
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
    keyVaultConnectionEnabled: true
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
      foundryName: foundry.outputs.FOUNDRY_NAME
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      projectId: i
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module ai_gateway '../modules/apim/ai-gateway-anthropic.bicep' = {
  name: 'ai-gateway-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    apimPublicEnabled: apimPublicEnabled
    resourceToken: resourceToken
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    aiFoundryProjectNames: [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
    anthropicServicesConfig: anthropicServicesConfig
    anthropicStaticModels: staticModels
    anthropicApiKey: anthropicApiKey
  }
}

module dashboard_setup '../modules/dashboard/dashboard-setup.bicep' = {
  name: 'dashboard-setup-deployment-${resourceToken}'
  params: {
    location: location
    applicationInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
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

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output apim_gateway_url string = ai_gateway.outputs.apimGatewayUrl
output anthropic_inference_url string = '${ai_gateway.outputs.apimGatewayUrl}/inference/anthropic'
output config_validation_result bool = valid_anthropic_config
