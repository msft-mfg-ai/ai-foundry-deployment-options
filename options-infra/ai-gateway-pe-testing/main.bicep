// This bicep file deploys one resource group with the following resources:
// 1. Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. Foundry account and projects
// 3. APIM as AI Gateway to allow Foundry Agent Service to use models from APIM
// 4. Projects with capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'
import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'

param location string = resourceGroup().location
param projectsCount int = 1
param apiServices apiType[] = []
param apimPublicEnabled bool = false

@description('Whether to create a Bing Grounding account and connection. Default true; set to false in subscriptions where the Bing resource provider is suspended or restricted. Ignored when `existingBingResourceId` is set.')
param enableBingGrounding bool = true

@description('Optional. Full resource ID of an existing Microsoft.Bing/accounts resource to connect to instead of creating a new one. When set, no new Bing account is created but a project connection is still made.')
param existingBingResourceId string = ''

@description('Existing Foundry / AI Services instances to front with the gateway. Discovered by the `preprovision-list-foundry-models` hook (FOUNDRY_INSTANCES_JSON). At least one instance is required.')
param foundryInstances foundryInstanceType[]

@description('Tenant IDs whose Entra ID tokens the gateway should accept on inbound calls. Empty (default) = no inbound JWT validation — callers reach the gateway anonymously and APIM\'s managed identity authenticates to Foundry. When set, the inbound policy requires a valid bearer token with `aud=https://cognitiveservices.azure.com` issued by one of these tenants.')
param acceptedTenantIds string[] = []

var tags = {
  'created-by': 'option-ai-gateway-pe-testing'
  'hidden-title': 'Foundry - APIM v2 Standard with PE Testing'
  SecurityControl: 'Insecure'
}
var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var valid_config = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the `preprovision-list-foundry-models` hook so FOUNDRY_INSTANCES_JSON is populated.')
  : true


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
    aiServicesName: '' // create AI services PE later
    aiAccountNameResourceGroupName: ''
  }
}

// Private endpoint per backing Foundry instance.
module openai_private_endpoints '../modules/networking/ai-pe-dns.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'openai-pe-${i}-${resourceToken}'
    params: {
      tags: tags
      location: location
      aiAccountName: last(split(instance.resourceId, '/'))
      aiAccountNameResourceGroup: split(instance.resourceId, '/')[4]
      aiAccountSubscriptionId: split(instance.resourceId, '/')[2]
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: '${resourceToken}-${i}'
      existingDnsZones: ai_dependencies.outputs.DNS_ZONES
    }
  }
]

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

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment-${resourceToken}'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    disableLocalAuth: false // enable local auth because AI Foundry needs it
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
    deployments: [] // no models
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

var projectNames = [for i in range(1, projectsCount): 'ai-project-${resourceToken}-${i}']

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, projectsCount): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      tags: tags
      location: location
      foundryName: foundry.outputs.FOUNDRY_NAME
      project_name: projectNames[i - 1]
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

module ai_gateway '../modules/apim/ai-gateway-pe.bicep' = {
  name: 'ai-gateway-pe-deployment'
  params: {
    tags: tags
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    resourceToken: resourceToken
    foundryInstances: foundryInstances
    foundryProjectNames: projectNames
    foundryName: foundry.outputs.FOUNDRY_NAME
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    apimPublicEnabled: apimPublicEnabled
    acceptedTenantIds: empty(acceptedTenantIds) ? [tenant().tenantId] : acceptedTenantIds
  }
}

module dashboard '../modules/dashboard/dashboard.bicep' = {
  name: 'dashboard-deployment-${resourceToken}'
  params: {
    location: location
    dashboardDisplayName: 'APIM Token Usage Dashboard for ${resourceToken}'
    applicationInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    applicationInsightsName: logAnalytics.outputs.APPLICATION_INSIGHTS_NAME
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
  }
}

// ── Azure Container Registry ─────────────────────────────────────────
// Provides an image store for Foundry Hosted Agents deployed via
// `create_version_from_image` (as opposed to `remote_build`, which does not
// require an ACR). AcrPull is granted to every project's managed identity so
// Foundry can pull images at agent-invocation time.
module acrDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'acr-privateDnsZoneDeployment'
  params: {
    tags: tags
    name: 'privatelink.azurecr.io'
    location: 'global'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
      }
    ]
  }
}

module containerRegistry '../modules/aml/container-registry.bicep' = {
  name: 'container-registry'
  params: {
    tags: tags
    location: location
    name: 'acr${resourceToken}'
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-acr-${resourceToken}'
    privateDnsZoneResourceId: acrDnsZone.outputs.resourceId
    principalIdsForPullPermission: [
      for i in range(0, projectsCount): identities[i].outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
    publicAccessEnabled: true // needed for `az acr build` from developer machine or GH-hosted runner
  }
}

// ── Bing Grounding tool ──────────────────────────────────────────────
// Either create a new Bing account, or reference an existing one, or skip.
var bingMode = !empty(existingBingResourceId)
  ? 'existing'
  : (enableBingGrounding ? 'create' : 'none')

module bing_connection '../modules/bing/connection-bing-grounding.bicep' = if (bingMode == 'create') {
  name: 'bing-connection-${resourceToken}'
  params: {
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    tags: tags
  }
}

// When bringing an existing Bing resource, create only the project connection.
resource foundryForBing 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = if (bingMode == 'existing') {
  name: 'ai-foundry-${resourceToken}'
}

var existingBingSub = bingMode == 'existing' ? split(existingBingResourceId, '/')[2] : ''
var existingBingRg = bingMode == 'existing' ? split(existingBingResourceId, '/')[4] : ''
var existingBingName = bingMode == 'existing' ? last(split(existingBingResourceId, '/')) : ''

resource existingBing 'Microsoft.Bing/accounts@2025-05-01-preview' existing = if (bingMode == 'existing') {
  name: existingBingName
  scope: resourceGroup(existingBingSub, existingBingRg)
}

resource existing_bing_project_connection 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = if (bingMode == 'existing') {
  name: 'binggrounding'
  parent: foundryForBing
  properties: {
    category: 'GroundingWithBingSearch'
    target: 'https://api.bing.microsoft.com/'
    authType: 'ApiKey'
    isSharedToAll: true
    credentials: {
      key: '${listKeys(existingBing.id, '2020-06-10').key1}'
    }
    metadata: {
      Type: 'bing_grounding'
      ApiType: 'Azure'
      ResourceId: existingBing.id
    }
  }
  dependsOn: [
    foundry
  ]
}

// module models_policy '../modules/policy/models-policy.bicep' = {
//   scope: subscription()
//   name: 'policy-definition-deployment-${resourceToken}'
// }

// module models_policy_assignment '../modules/policy/models-policy-assignment.bicep' = {
//   name: 'policy-assignment-deployment-${resourceToken}'
//   params: {
//     cognitiveServicesPolicyDefinitionId: models_policy.outputs.cognitiveServicesPolicyDefinitionId
//     allowedCognitiveServicesModels: []
//   }
//   dependsOn: [openai_with_models]
// }

module mcp_apis '../modules/apps/apps-private-link.bicep' = if (!empty(apiServices)) {
  name: 'mcp-apis-private-link-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    apimServiceName: ai_gateway.outputs.apimName
    apimGatewayUrl: ai_gateway.outputs.apimGatewayUrl
    apimAppInsightsLoggerId: ai_gateway.outputs.apimAppInsightsLoggerId
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    externalApis: apiServices
  }
}

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output PROJECT_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${first(projectNames)}'
output FOUNDRY_ACCOUNT_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com'
output FOUNDRY_REGION string = location
output AI_GATEWAY_CONNECTION_STATIC string = 'apim-${resourceToken}-openai-s-for-${first(projectNames)}'
output AI_GATEWAY_CONNECTION_DYNAMIC string = 'apim-${resourceToken}-openai-d-for-${first(projectNames)}'
output AI_GATEWAY_CONNECTION_ANTHROPIC string = 'apim-${resourceToken}-anthropic-s-for-${first(projectNames)}'
output AI_GATEWAY_CONNECTION_ANTHROPIC_DYNAMIC string = 'apim-${resourceToken}-anthropic-d-for-${first(projectNames)}'
output RESOURCE_GROUP string = resourceGroup().name
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output BING_CONNECTION_ID string = bingMode == 'none'
  ? ''
  : '${foundry.outputs.FOUNDRY_RESOURCE_ID}/projects/${first(projectNames)}/connections/binggrounding'
output AZURE_AI_SEARCH_CONNECTION_ID string = '${foundry.outputs.FOUNDRY_RESOURCE_ID}/projects/${first(projectNames)}/connections/${ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name}-for-${first(projectNames)}'
output AI_SEARCH_SERVICE_NAME string = ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name
output AI_SEARCH_ENDPOINT string = 'https://${ai_dependencies.outputs.AI_DEPENDECIES.aiSearch.name}.search.windows.net'
output AZURE_AI_SEARCH_INDEX_NAME string = 'byom-test'
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
output HOSTED_AGENT_IMAGE string = '${containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER}/byom-hosted-agent:latest'
output config_validation_result bool = valid_config
