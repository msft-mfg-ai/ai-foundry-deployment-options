// Deploys Azure AI Foundry with an APIM AI Gateway configured to proxy Claude (Anthropic)
// models hosted on a Foundry account. Designed for scenarios where the Anthropic Foundry
// account can be reached by APIM using managed identity.
//
// Infrastructure deployed:
//  - VNet + private DNS zones
//  - Foundry account + projects with capability hosts
//  - Key Vault, Log Analytics, App Insights
//  - APIM Standardv2 (External VNet) with private endpoint
//  - Shared pass-through inference API at {gateway}/inference
//  - Foundry connections (static model list, deploymentInPath=false)

targetScope = 'resourceGroup'

import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'
import { ModelType } from '../modules/ai/connection-apim-gateway.bicep'

param location string = resourceGroup().location

@description('Existing Foundry / AI Services instances to front with the gateway. Discovered by the `preprovision-list-foundry-models` hook (FOUNDRY_INSTANCES_JSON). At least one instance is required.')
param foundryInstances foundryInstanceType[]

@description('Location for Foundry dependency resources (Storage, AI Search, Cosmos DB). Defaults to `location`. Override when the primary region does not allow one of the services (e.g. AI Search in eastus2).')
param dependenciesLocation string = location

@description('Number of Foundry projects to create.')
param projectsCount int = 1

@description('Allow public access to APIM. Set to true for testing; false for production.')
param apimPublicEnabled bool = true

var tags = {
  'created-by': 'option-ai-gateway-anthropic'
  'hidden-title': 'Foundry - Anthropic AI Gateway (APIM v2 Standard with PE)'
  SecurityControl: 'Ignore'
}

var valid_anthropic_config = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the `preprovision-list-foundry-models` hook so FOUNDRY_INSTANCES_JSON is populated.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

var allDeployments = flatten(map(foundryInstances, inst => inst.deployments))
var dedupedDeployments = reduce(
  allDeployments,
  [],
  (acc, d) => contains(map(acc, x => x.modelName), d.modelName) ? acc : concat(acc, [d])
)
var staticModels ModelType[] = [
  for d in dedupedDeployments: {
    name: d.modelName
    properties: {
      model: {
        name: d.modelName
        version: d.?modelVersion ?? ''
        format: d.?modelFormat ?? 'Anthropic'
      }
    }
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
    dependenciesLocation: dependenciesLocation
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: ''
    aiAccountNameResourceGroupName: ''
  }
}

// Cross-tenant private endpoints for the Anthropic-hosting Foundry account(s).
// Uses manualPrivateLinkServiceConnections — requires approval on the target tenant.
module anthropic_foundry_private_endpoint_cross_tenant '../modules/networking/ai-pe-dns-cross-tenant.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false) && split(instance.resourceId, '/')[2] != subscription().subscriptionId) {
    name: 'anthropic-foundry-pe-cross-${i}-${resourceToken}'
    params: {
      tags: tags
      location: location
      aiAccountResourceId: instance.resourceId
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: '${resourceToken}-${i}'
      existingDnsZones: ai_dependencies.outputs.DNS_ZONES
    }
  }
]

module anthropic_foundry_private_endpoint '../modules/networking/ai-pe-dns.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false) && split(instance.resourceId, '/')[2] == subscription().subscriptionId) {
    name: 'anthropic-foundry-pe-${i}-${resourceToken}'
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
    foundryInstances: foundryInstances
    anthropicStaticModels: staticModels
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
