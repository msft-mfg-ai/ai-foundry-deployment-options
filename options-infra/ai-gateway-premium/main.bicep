metadata name = 'API Management v2 Premium with VNET Injections (Internal)'
metadata description = 'Deploys API Management v2 Premium with VNET Injections (Internal) mode and custom domain, integrated with Foundry as an AI Gateway to allow Foundry Agent Service to use models from APIM.'

targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'
import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'
import { ModelType } from '../modules/ai/connection-apim-gateway.bicep'

param location string = resourceGroup().location
param apimLocation string = location
param projectsCount int = 3
param apiServices apiType[] = []

@description('Existing Foundry / AI Services instances to front with the gateway. Discovered by the `preprovision-list-foundry-models` hook (FOUNDRY_INSTANCES_JSON). At least one instance is required.')
param foundryInstances foundryInstanceType[]

@description('Tenant IDs whose Entra ID tokens the gateway should accept on inbound calls. Empty (default) = no inbound JWT validation — callers reach the gateway anonymously and APIM\'s managed identity authenticates to Foundry. When set, the inbound policy requires a valid bearer token with `aud=https://cognitiveservices.azure.com` issued by one of these tenants.')
param acceptedTenantIds string[] = []

var certFilePath = '../../../../../.ssh/cloud.karpala.pfx'
var certFileBase64 = loadFileAsBase64(certFilePath)
param customDomain string = 'cloud.karpala.org'

var tags = {
  'created-by': 'option-ai-gateway'
  'hidden-title': 'Foundry - APIM Premium with VNET Injection (Internal)'
  SecurityControl: 'Ignore'
}

var valid_config = empty(foundryInstances)
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
        version: d.?modelVersion ?? '2025-01-01-preview'
        format: d.?modelFormat ?? 'OpenAI'
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

module apim_identity '../modules/iam/identity.bicep' = {
  name: 'apim-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'apim-${resourceToken}-identity'
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

module apim_vnet '../modules/networking/vnet-apim.bicep' = {
  name: 'apim-vnet-deployment'
  params: {
    tags: tags
    location: apimLocation
    vnetName: 'apim-vnet-${resourceToken}'
    peeringResourceIds: [
      vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    ]
  }
}

module dns_zone_linking '../modules/networking/dns-zones.bicep' = {
  name: 'dns-zone-linking-deployment'
  params: {
    vnetResourceIds: [
      apim_vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    ]
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

// Private endpoint per backing Foundry instance — each may live in a different
// subscription/RG. The PE goes into THIS deployment's VNet so the Internal-VNet
// APIM can reach the upstream models.
//
// Skip chained-APIM instances (isApim=true) — they're not Cognitive Services
// accounts; the downstream APIM exposes its own endpoint.
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
    userAssignedManagedIdentityPrincipalIds: [
      foundry_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
    publicAccessEnabled: false
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-kv-foundry-${resourceToken}'
    privateDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.vaultcore.azure.net']!.resourceId
  }
}

module keyVault_for_apim '../modules/kv/key-vault.bicep' = {
  name: 'key-vault-deployment-for-apim'
  params: {
    tags: tags
    location: apimLocation
    name: take('kv-apim-${resourceToken}', 24)
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    doRoleAssignments: true
    secrets: [
      { name: 'customdomaincert', value: certFileBase64, contentType: 'application/x-pkcs12' }
    ]
    userAssignedManagedIdentityPrincipalIds: [
      apim_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
    publicAccessEnabled: false
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-kv-apim-${resourceToken}'
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

var effectiveHostnameConfigurations = [
  {
    type: 'Proxy'
    hostName: 'apim.${customDomain}'
    certificateSource: 'KeyVault'
    keyVaultId: keyVault_for_apim.outputs.KEY_VAULT_SECRETS_URIS[0]
  }
]

module ai_gateway '../modules/apim/ai-gateway-premium.bicep' = {
  name: 'ai-gateway-premium-deployment'
  params: {
    tags: tags
    location: apimLocation
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    resourceToken: resourceToken
    foundryInstances: foundryInstances
    foundryProjectNames: projectNames
    foundryName: foundry.outputs.FOUNDRY_NAME
    subnetResourceId: apim_vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2PremiumSubnet.resourceId
    vnetResourceIds: [apim_vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID, vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID]
    acceptedTenantIds: acceptedTenantIds
    apimUserAssignedManagedIdentityResourceId: apim_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    hostnameConfigurations: effectiveHostnameConfigurations
    customDomain: customDomain
    keyVaultName: keyVault_for_apim.outputs.KEY_VAULT_NAME
  }
  dependsOn: [dns_zone_linking]
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

module mcp_apis '../modules/apps/apps-private-link.bicep' = {
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
output config_validation_result bool = valid_config
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
