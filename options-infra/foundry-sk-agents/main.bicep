// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. One AI Project with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param projectsCount int = 1
var tags = {
  'created-by': 'foundry-sk-agents'
  'hidden-title': 'Foundry Standard - BYO Vnet with SK Agents'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var AZURE_OPENAI_DEPLOYMENT = 'gpt-4.1-mini'

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
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

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: '' // Use System Assigned Identity
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
    deployments: [
      {
        name: AZURE_OPENAI_DEPLOYMENT
        properties: {
          model: {
            format: 'OpenAI'
            name: AZURE_OPENAI_DEPLOYMENT
            version: '2025-04-14'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
    ]
  }
}

module project_identities '../modules/iam/identity.bicep' = [
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
      managedIdentityResourceId: project_identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module managedEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'container-app-environment'
  params: {
    tags: tags
    location: location
    name: 'aca-environment-${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    infrastructureSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.acaSubnet.resourceId
    appInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    publicNetworkAccess: 'Enabled'
  }
}

module app_identity '../modules/iam/identity.bicep' = {
  name: 'app-identity-deployment'
  params: {
    tags: tags
    location: location
    identityName: 'app-identity-${resourceToken}'
  }
}

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
    privateDnsZoneResourceId: acrDnsZone.outputs.resourceId
    principalIdsForPullPermission: [
      app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
    publicAccessEnabled: true
  }
}

module foundryProjectRoleAssignments '../modules/iam/role-assignment-foundryProject.bicep' = {
  name: take('role-assignments-foundry-project-${resourceToken}', 64)
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectName: projects[0].outputs.FOUNDRY_PROJECT_NAME
    projectPrincipalId: app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    roleName: 'Azure AI User'
  }
}

module appAgents '../modules/aca/container-app.bicep' = {
  name: 'app-sk-agents'
  dependsOn: [appFileProcessor] // Ensure file processor is deployed first
  params: {
    tags: tags
    location: location
    name: 'aca-sk-agents'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    definition: {
      settings: [
        {
          name: 'AZURE_AI_PROJECT_CONNECTION_STRING'
          value: projects[0].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
        }
        {
          name: 'FILE_PROCESSOR_URL'
          value: 'https://aca-file-processor.internal.${managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN}'
        }
        {
          name: 'AZURE_OPENAI_DEPLOYMENT'
          value: AZURE_OPENAI_DEPLOYMENT
        }
        {
          name: 'OTEL_PYTHON_EXCLUDED_URLS'
          value: '/health,/healthz,/ready,/readiness,/liveness,/invoke/stream'
        }
      ]
    }
    ingressTargetPort: 3000
    userAssignedManagedIdentityClientId: app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: true
    cpu: '0.5'
    memory: '1Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 3000
        }
      }
    ]
  }
}

module appFileProcessor '../modules/aca/container-app.bicep' = {
  name: 'app-file-processor'
  params: {
    tags: tags
    location: location
    name: 'aca-file-processor'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    definition: {
      settings: [
        {
          name: 'PROCESSING_DELAY_SECONDS'
          value: '20' // 20 seconds
        }
        {
          name: 'OTEL_PYTHON_EXCLUDED_URLS'
          value: '/health,/healthz,/ready,/readiness,/liveness'
        }
      ]
    }
    ingressTargetPort: 3000
    userAssignedManagedIdentityClientId: app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressExternal: false // Internal only, accessed by sk-agents
    cpu: '0.25'
    memory: '0.5Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    containerAppsEnvironmentResourceId: managedEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 3000
        }
      }
    ]
  }
}

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = [for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]

// Container Apps outputs for AZD
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_NAME

output SERVICE_SK_AGENTS_ENDPOINTS array = [appAgents.outputs.CONTAINER_APP_FQDN]
output SERVICE_SK_AGENTS_NAME string = appAgents.outputs.CONTAINER_APP_NAME
output SERVICE_SK_AGENTS_RESOURCE_ID string = appAgents.outputs.CONTAINER_APP_RESOURCE_ID

output SERVICE_FILE_PROCESSOR_ENDPOINTS array = [appFileProcessor.outputs.CONTAINER_APP_FQDN]
output SERVICE_FILE_PROCESSOR_NAME string = appFileProcessor.outputs.CONTAINER_APP_NAME
output SERVICE_FILE_PROCESSOR_RESOURCE_ID string = appFileProcessor.outputs.CONTAINER_APP_RESOURCE_ID

output APPLICATIONINSIGHTS_CONNECTION_STRING string = logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
output APP_IDENTITY_CLIENT_ID string = app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
