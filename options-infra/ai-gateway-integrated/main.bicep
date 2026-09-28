// Deploys two private Foundry accounts, one project per account, and one shared
// private AI Gateway. Each Foundry uses a dedicated delegated agent subnet.
targetScope = 'resourceGroup'

import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'

param location string = resourceGroup().location

@description('Existing Foundry / AI Services instances whose model deployments are exposed through the shared gateway.')
param foundryInstances foundryInstanceType[]

@description('Keep the APIM public endpoint enabled after its private endpoint is created.')
param apimPublicEnabled bool = false

@description('Tenant IDs whose Entra ID tokens the gateway accepts. Defaults to the deployment tenant.')
param acceptedTenantIds string[] = []

var tags = {
  'created-by': 'option-ai-gateway-integrated'
  'hidden-title': 'Two private Foundries integrated with one AI Gateway'
}
var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var foundryCount = 2
var foundryNames = [for i in range(0, foundryCount): 'ai-foundry-${resourceToken}-${i + 1}']
var projectNames = [for i in range(0, foundryCount): 'ai-project-${resourceToken}-${i + 1}']
var validConfig = empty(foundryInstances)
  ? fail('No gateway backend instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS (or OPENAI_RESOURCE_ID) and run the preprovision hook.')
  : true

module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'integrated-vnet-${resourceToken}'
    vnetAddressPrefix: '192.168.0.0/20'
    extraAgentSubnets: 1
  }
}

var agentSubnetResourceIds = [
  vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
  first(vnet.outputs.VIRTUAL_NETWORK_SUBNETS.extraAgentSubnets)!.resourceId
]

module aiDependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: ''
    aiAccountNameResourceGroupName: ''
    semanticSearch: 'free'
  }
}

module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-integrated-${resourceToken}'
    newApplicationInsightsName: 'appi-integrated-${resourceToken}'
  }
}

module foundryIdentities '../modules/iam/identity.bicep' = [
  for i in range(0, foundryCount): {
    name: 'foundry-${i + 1}-identity'
    params: {
      tags: tags
      location: location
      identityName: 'foundry-${resourceToken}-${i + 1}-identity'
    }
  }
]

@batchSize(1)
module foundries '../modules/ai/ai-foundry.bicep' = [
  for i in range(0, foundryCount): {
    name: 'foundry-${i + 1}'
    params: {
      tags: tags
      location: location
      managedIdentityResourceId: foundryIdentities[i].outputs.MANAGED_IDENTITY_RESOURCE_ID
      name: foundryNames[i]
      disableLocalAuth: false
      publicNetworkAccess: 'Disabled'
      agentSubnetResourceId: agentSubnetResourceIds[i]
      deployments: []
    }
  }
]

module foundryPrivateEndpoints '../modules/networking/ai-pe-dns.bicep' = [
  for i in range(0, foundryCount): {
    name: 'foundry-${i + 1}-private-endpoint'
    params: {
      tags: tags
      location: location
      aiAccountName: foundries[i].outputs.FOUNDRY_NAME
      aiAccountNameResourceGroup: resourceGroup().name
      aiAccountSubscriptionId: subscription().subscriptionId
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: 'foundry-${resourceToken}-${i + 1}'
      existingDnsZones: aiDependencies.outputs.DNS_ZONES
    }
  }
]

module projectIdentities '../modules/iam/identity.bicep' = [
  for i in range(0, foundryCount): {
    name: 'project-${i + 1}-identity'
    params: {
      tags: tags
      location: location
      identityName: 'project-${resourceToken}-${i + 1}-identity'
    }
  }
]

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(0, foundryCount): {
    name: 'project-${i + 1}-with-caphost'
    params: {
      tags: tags
      location: location
      foundryName: foundries[i].outputs.FOUNDRY_NAME
      project_name: projectNames[i]
      project_description: 'Project ${i + 1} integrated with the shared AI Gateway'
      display_name: 'Integrated Project ${i + 1}'
      projectId: i + 1
      aiDependencies: aiDependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: projectIdentities[i].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

// Private endpoints let APIM reach each external model backend without using
// the public data plane.
module backendPrivateEndpoints '../modules/networking/ai-pe-dns.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'gateway-backend-${i}-private-endpoint'
    params: {
      tags: tags
      location: location
      aiAccountName: last(split(instance.resourceId, '/'))
      aiAccountNameResourceGroup: split(instance.resourceId, '/')[4]
      aiAccountSubscriptionId: split(instance.resourceId, '/')[2]
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: 'backend-${resourceToken}-${i}'
      existingDnsZones: aiDependencies.outputs.DNS_ZONES
    }
  }
]

module apim '../modules/apim/v2/apim.bicep' = {
  name: 'apim'
  params: {
    apiManagementName: 'apim-ai-${resourceToken}'
    tags: tags
    location: location
    apimSku: 'Standardv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    virtualNetworkType: 'External'
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    publicNetworkAccess: 'Enabled'
  }
}

module apimPrivateEndpoint '../modules/apim/apim-pe.bicep' = {
  name: 'apim-private-endpoint'
  params: {
    tags: tags
    location: location
    apimName: apim.outputs.name
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
  }
}

module gatewaySetup '../modules/apim/common-apim-setup.bicep' = {
  name: 'common-ai-gateway-setup'
  params: {
    apimName: apim.outputs.name
    apimLoggerId: apim.outputs.loggerId
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    gatewayAuthenticationType: 'ProjectManagedIdentity'
    acceptedTenantIds: empty(acceptedTenantIds) ? [tenant().tenantId] : acceptedTenantIds
    foundryInstances: foundryInstances
    foundryAccountApiNames: foundryNames
    apimSku: 'Standardv2'
    location: location
  }
}

module accountGatewayArtifacts './modules/account-ai-gateway.bicep' = [
  for i in range(0, foundryCount): {
    name: 'foundry-${i + 1}-gateway-artifacts'
    dependsOn: [
      gatewaySetup
    ]
    params: {
      aiFoundryAccountName: foundryNames[i]
      apimResourceId: apim.outputs.id
    }
  }
]

// Each product is associated with its account-named API for Foundry control
// plane correlation. Runtime project connections use the canonical inference
// API so routing policy, backend pools, and quota counters remain shared.
module gatewayIntegrations './modules/project-ai-gateway.bicep' = [
  for i in range(0, foundryCount): {
    name: 'project-${i + 1}-gateway-integration'
    dependsOn: [
      gatewaySetup
      accountGatewayArtifacts[i]
      projects[i]
    ]
    params: {
      aiFoundryAccountName: foundryNames[i]
      projectName: projectNames[i]
      apimResourceId: apim.outputs.id
      sharedApiId: toLower(foundryNames[i])
    }
  }
]

module gatewayConnections '../modules/ai/connections-apim-gateway.bicep' = [
  for i in range(0, foundryCount): {
    name: 'project-${i + 1}-gateway-connections'
    dependsOn: [
      gatewayIntegrations[i]
    ]
    params: {
      aiFoundryName: foundryNames[i]
      aiFoundryProjectNames: [projectNames[i]]
      resourceToken: resourceToken
      gatewayAuthenticationType: 'ProjectManagedIdentity'
      staticModels: gatewaySetup.outputs.staticModels
      apimResourceId: apim.outputs.id
      apimSubscriptionNames: [gatewayIntegrations[i].outputs.subscriptionName]
      inferenceApiName: gatewaySetup.outputs.inferenceApiName
    }
  }
]

module apimServiceUpdate '../modules/apim/v2/apim.bicep' = if (!apimPublicEnabled) {
  name: 'apim-disable-public-access'
  dependsOn: [
    apimPrivateEndpoint
    gatewayConnections
  ]
  params: {
    apiManagementName: apim.outputs.name
    tags: tags
    location: location
    apimSku: 'Standardv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    virtualNetworkType: 'External'
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    publicNetworkAccess: 'Disabled'
  }
}

module apimRoleAssignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in foundryInstances: if (!(instance.?isApim ?? false)) {
    name: 'apim-backend-role-${i}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: apim.outputs.principalId
      roleName: 'Cognitive Services User'
    }
  }
]

output FOUNDRY_NAMES string[] = foundryNames
output PROJECT_NAMES string[] = projectNames
output PROJECT_ENDPOINTS string[] = [
  for i in range(0, foundryCount): 'https://${foundryNames[i]}.services.ai.azure.com/api/projects/${projectNames[i]}'
]
output AI_GATEWAY_CONNECTION_STATIC string[] = [
  for i in range(0, foundryCount): 'apim-${resourceToken}-openai-s-for-${projectNames[i]}'
]
output AI_GATEWAY_CONNECTION_DYNAMIC string[] = [
  for i in range(0, foundryCount): 'apim-${resourceToken}-openai-d-for-${projectNames[i]}'
]
output AI_GATEWAY_PRODUCT_NAMES string[] = [
  for i in range(0, foundryCount): gatewayIntegrations[i].outputs.productName
]
output APIM_BASE_URL string = apim.outputs.gatewayUrl
output APIM_RESOURCE_ID string = apim.outputs.id
output VIRTUAL_NETWORK_NAME string = vnet.outputs.VIRTUAL_NETWORK_NAME
output AGENT_SUBNET_RESOURCE_IDS string[] = agentSubnetResourceIds
output config_validation_result bool = validConfig
