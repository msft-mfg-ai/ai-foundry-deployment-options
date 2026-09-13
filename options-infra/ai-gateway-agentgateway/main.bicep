targetScope = 'resourceGroup'

import { foundryInstanceType } from '../modules/apim/advanced/types.bicep'

param location string = resourceGroup().location
@description('Optional region override for Azure AI Search when the gateway region has no capacity.')
param aiSearchLocation string = ''
@description('Existing Foundry / AI Services instances discovered by the standard preprovision hook from EXISTING_FOUNDRY_RESOURCE_IDS.')
param foundryInstances foundryInstanceType[]
param gatewayApiClientId string
param gatewayAudience string
param uiClientId string
@secure()
param uiClientSecret string
@secure()
param oidcCookieSecret string
param agentgatewayImage string = 'cr.agentgateway.dev/agentgateway:v1.5.0'

var selectedFoundryInstances = filter(foundryInstances, instance => !(instance.?isApim ?? false))
var discoveredDeployments = flatten(map(selectedFoundryInstances, instance => map(instance.deployments, deployment => {
  instanceName: instance.name
  resourceName: last(split(instance.resourceId, '/'))
  modelName: deployment.modelName
  modelVersion: deployment.?modelVersion ?? ''
  modelFormat: deployment.?modelFormat ?? 'OpenAI'
  weight: instance.?weight ?? 1
})))
var validFoundryInstances = empty(foundryInstances)
  ? fail('No Foundry instances configured. Set EXISTING_FOUNDRY_RESOURCE_IDS and run the preprovision discovery hook.')
  : true
var validFoundryDeployments = empty(discoveredDeployments)
  ? fail('The selected Foundry instances do not contain any model deployments.')
  : true
var validFoundrySources = length(selectedFoundryInstances) != length(foundryInstances)
  ? fail('ai-gateway-agentgateway accepts Foundry / AI Services resource IDs, not chained APIM gateway URLs.')
  : true
var validEntra = empty(gatewayApiClientId) || empty(gatewayAudience) || empty(uiClientId) || empty(uiClientSecret) || empty(oidcCookieSecret)
  ? fail('The agentgateway Entra preprovision hook did not populate all required values.')
  : true
var tags = {
  'created-by': 'option-ai-gateway-agentgateway'
  'hidden-title': 'Foundry - agentgateway unified gateway'
}
var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var resolvedAiSearchLocation = empty(aiSearchLocation) ? location : aiSearchLocation
var modelNames = union([], map(discoveredDeployments, deployment => deployment.modelName))
var staticModels = [
  for modelName in modelNames: {
    name: modelName
    properties: {
      model: {
        name: modelName
        version: first(filter(discoveredDeployments, deployment => deployment.modelName == modelName))!.modelVersion
        format: first(filter(discoveredDeployments, deployment => deployment.modelName == modelName))!.modelFormat
      }
    }
  }
]
var azureClientIdReference = format('{0}{1}', '$', '{AZURE_CLIENT_ID}')
var agentgatewayModelsYaml = join(
  map(
    discoveredDeployments,
    deployment => format(
      '  - name: \'{0}/{1}\'\n    provider: azure\n    auth:\n      azure:\n        explicitConfig:\n          managedIdentity:\n            userAssignedIdentity:\n              clientId: {2}\n    params:\n      azureResourceName: \'{3}\'\n      azureResourceType: openAI\n      model: \'{1}\'',
      deployment.instanceName,
      deployment.modelName,
      azureClientIdReference,
      deployment.resourceName
    )
  ),
  '\n'
)
var agentgatewayVirtualModelTargets = map(
  modelNames,
  modelName => join(
    map(
      filter(discoveredDeployments, deployment => deployment.modelName == modelName),
      deployment => format(
        '        - model: \'{0}/{1}\'\n          weight: {2}',
        deployment.instanceName,
        deployment.modelName,
        deployment.weight
      )
    ),
    '\n'
  )
)
var agentgatewayVirtualModelsYaml = join(
  map(
    modelNames,
    (modelName, i) => format(
      '  - name: \'{0}\'\n    routing:\n      weighted:\n        targets:\n{1}',
      modelName,
      agentgatewayVirtualModelTargets[i]
    )
  ),
  '\n'
)
var gatewayConfig = replace(
  loadTextContent('./gateway/config.yaml'),
  '__LLM_CONFIG__',
  format(
    '  models:\n{0}\n  virtualModels:\n{1}',
    agentgatewayModelsYaml,
    agentgatewayVirtualModelsYaml
  )
)

module gatewayIdentity '../modules/iam/identity.bicep' = {
  name: 'agentgateway-identity'
  params: {
    tags: tags
    location: location
    identityName: 'agentgateway-${resourceToken}-identity'
  }
}

module foundryIdentity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity'
  params: {
    tags: tags
    location: location
    identityName: 'foundry-${resourceToken}-identity'
  }
}

module projectIdentity '../modules/iam/identity.bicep' = {
  name: 'project-identity'
  params: {
    tags: tags
    location: location
    identityName: 'project-${resourceToken}-identity'
  }
}

module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'agentgateway-vnet-${resourceToken}'
    vnetAddressPrefix: '192.168.0.0/20'
    extraAgentSubnets: 1
  }
}

module dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies'
  params: {
    tags: tags
    location: location
    aiSearchLocation: resolvedAiSearchLocation
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: ''
    aiAccountNameResourceGroupName: ''
  }
}

module foundryPrivateEndpoints '../modules/networking/ai-pe-dns.bicep' = [
  for (instance, i) in selectedFoundryInstances: {
    name: 'foundry-private-endpoint-${i}'
    params: {
      tags: tags
      location: location
      aiAccountName: last(split(instance.resourceId, '/'))
      aiAccountNameResourceGroup: split(instance.resourceId, '/')[4]
      aiAccountSubscriptionId: split(instance.resourceId, '/')[2]
      peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
      resourceToken: 'foundry-${i}-${resourceToken}'
      existingDnsZones: dependencies.outputs.DNS_ZONES
    }
  }
]

module foundryRoles '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for (instance, i) in selectedFoundryInstances: {
    name: 'agentgateway-foundry-role-${i}'
    scope: resourceGroup(split(instance.resourceId, '/')[2], split(instance.resourceId, '/')[4])
    params: {
      accountName: last(split(instance.resourceId, '/'))
      principalId: gatewayIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      roleName: 'Cognitive Services OpenAI User'
    }
  }
]

module monitoring '../modules/monitor/loganalytics.bicep' = {
  name: 'monitoring'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-agentgateway-${resourceToken}'
    newApplicationInsightsName: 'appi-agentgateway-${resourceToken}'
  }
}

module keyVault '../modules/kv/key-vault.bicep' = {
  name: 'key-vault'
  params: {
    tags: tags
    location: location
    name: take('kv-agw-${resourceToken}', 24)
    logAnalyticsWorkspaceId: monitoring.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    doRoleAssignments: true
    secrets: []
    userAssignedManagedIdentityPrincipalIds: [
      gatewayIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
    principalId: null
    publicAccessEnabled: false
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    privateEndpointName: 'pe-kv-agw-${resourceToken}'
    privateDnsZoneResourceId: dependencies.outputs.DNS_ZONES['privatelink.vaultcore.azure.net']!.resourceId
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: foundryIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: []
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
  }
}

module project '../modules/ai/ai-project-with-caphost.bicep' = {
  name: 'project-with-caphost'
  params: {
    tags: tags
    location: location
    foundryName: foundry.outputs.FOUNDRY_NAME
    project_name: 'ai-project-${resourceToken}-1'
    project_description: 'agentgateway sample project ${resourceToken}'
    display_name: 'agentgateway sample project ${resourceToken}'
    projectId: 1
    aiDependencies: dependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: null
    managedIdentityResourceId: projectIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: monitoring.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

module postgresDns 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'postgres-dns'
  params: {
    tags: tags
    name: 'privatelink.postgres.database.azure.com'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
      }
    ]
  }
}

module registry '../modules/aml/container-registry.bicep' = {
  name: 'container-registry'
  params: {
    tags: tags
    location: location
    name: 'acragw${resourceToken}'
    logAnalyticsWorkspaceId: monitoring.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    publicAccessEnabled: true
    principalIdsForPullPermission: [
      gatewayIdentity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
  }
}

module sampleEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'sample-environment'
  params: {
    tags: tags
    location: location
    name: 'aca-samples-${resourceToken}'
    logAnalyticsWorkspaceResourceId: monitoring.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsConnectionString: monitoring.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    publicNetworkAccess: 'Enabled'
    infrastructureSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.acaSubnet.resourceId
  }
}

module mcpServer '../modules/aca/container-app.bicep' = {
  name: 'mcp-server'
  params: {
    tags: tags
    location: location
    name: 'mcp-server'
    workloadProfileName: sampleEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: monitoring.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    definition: { settings: [] }
    ingressTargetPort: 8000
    existingImage: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    userAssignedManagedIdentityClientId: gatewayIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: gatewayIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: false
    cpu: '0.5'
    memory: '1Gi'
    scaleMinReplicas: 1
    scaleMaxReplicas: 2
    containerRegistryLoginServer: registry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: sampleEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: { path: '/health', port: 8000 }
      }
    ]
  }
}

module a2aAgent '../modules/aca/container-app.bicep' = {
  name: 'a2a-agent'
  params: {
    tags: tags
    location: location
    name: 'a2a-agent'
    workloadProfileName: sampleEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: monitoring.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    definition: { settings: [] }
    ingressTargetPort: 8000
    existingImage: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
    userAssignedManagedIdentityClientId: gatewayIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: gatewayIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: false
    cpu: '0.5'
    memory: '1Gi'
    scaleMinReplicas: 1
    scaleMaxReplicas: 2
    containerRegistryLoginServer: registry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: sampleEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: { path: '/health', port: 8000 }
      }
    ]
  }
}

module agentgateway '../modules/agentgateway/agentgateway.bicep' = {
  name: 'agentgateway'
  params: {
    tags: tags
    location: location
    resourceToken: resourceToken
    logAnalyticsWorkspaceResourceId: monitoring.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    applicationInsightsConnectionString: monitoring.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    containerAppsEnvironmentResourceId: sampleEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    containerAppsEnvironmentDefaultDomain: sampleEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN
    containerAppsWorkloadProfileName: sampleEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    keyVaultName: keyVault.outputs.KEY_VAULT_NAME
    postgresDnsZoneResourceId: postgresDns.outputs.resourceId
    identityResourceId: gatewayIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    identityClientId: gatewayIdentity.outputs.MANAGED_IDENTITY_CLIENT_ID
    foundryName: foundry.outputs.FOUNDRY_NAME
    foundryProjectName: project.outputs.FOUNDRY_PROJECT_NAME
    staticModels: staticModels
    gatewayConfigYaml: gatewayConfig
    gatewayApiClientId: gatewayApiClientId
    gatewayAudience: gatewayAudience
    tenantId: tenant().tenantId
    uiClientId: uiClientId
    uiClientSecret: uiClientSecret
    oidcCookieSecret: oidcCookieSecret
    mcpTargetUrl: '${mcpServer.outputs.CONTAINER_APP_FQDN}/mcp/'
    a2aTargetUrl: '${replace(a2aAgent.outputs.CONTAINER_APP_FQDN, 'https://', '')}:443'
    agentgatewayImage: agentgatewayImage
  }
}

output AGENTGATEWAY_URL string = agentgateway.outputs.gatewayUrl
output AGENTGATEWAY_UI_URL string = agentgateway.outputs.uiUrl
output AGENTGATEWAY_MCP_URL string = agentgateway.outputs.mcpUrl
output AGENTGATEWAY_A2A_URL string = agentgateway.outputs.a2aUrl
output FOUNDRY_PROJECT_NAME string = project.outputs.FOUNDRY_PROJECT_NAME
output FOUNDRY_PROJECT_CONNECTION_STRING string = project.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.AZURE_CONTAINER_REGISTRY_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
output CONFIG_VALIDATION_RESULT bool = validFoundryInstances && validFoundryDeployments && validFoundrySources && validEntra
