// template simulates a simple landing zone deployment (shared infrastructure) with azure Open AI
// this would go to AI-Subscription and build services that can be shared with app-landing-zone
// Deployment creates 2 AI Services: one private and one public
param location string = resourceGroup().location

param resourceToken string = toLower(uniqueString(resourceGroup().id, location))
param aiServicesName string = 'foundry-landing-zone-${location}-${resourceToken}'
param aiServicesPublicName string = 'foundry-landing-zone-${location}-PUBLIC-${resourceToken}'

// Foundry doesn't support cross-subscription VNet injection or cross subscription resources, so we need to deploy it in the same subscription
var doesFoundrySupportsCrossSubscriptionVnet = false

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'mgmtidentity-${uniqueString(deployment().name, location)}'
  params: {
    name: 'landing-zone-identity-${resourceToken}'
    location: location
  }
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'log-${resourceToken}'
  params: {
    name: 'loganaly01'
    dataRetention: 30
    features: { immediatePurgeDataOn30Days: true, disableLocalAuth: false }
    managedIdentities: {
      userAssignedResourceIds: [identity.outputs.resourceId]
    }
  }
}

module appInsights 'br/public:avm/res/insights/component:0.7.1' = {
  name: 'appinsights-${resourceToken}'
  params: {
    name: 'appinsights01'
    workspaceResourceId: logAnalytics.outputs.resourceId
    applicationType: 'web'
    disableLocalAuth: false
    roleAssignments: [
      {
        roleDefinitionIdOrName: 'Monitoring Contributor'
        principalId: identity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

module apps '../modules/function/function-app-with-plan.bicep' = {
  name: 'function-app'
  params: {
    name: 'apps'
    applicationInsightResourceId: appInsights.outputs.resourceId
    artifactUrl: 'https://github.com/karpikpl/weather-MCP-OpenAPI-server/blob/main/artifacts/azure-functions-package.zip?raw=true'
    managedIdentityResourceId: identity.outputs.resourceId
    location: 'canadacentral'
    privateEndpointSubnetResourceId: null // No private endpoint for this example
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    resourceToken: resourceToken
  }
}

module aiServices '../modules/ai/ai-foundry.bicep' = {
  name: 'ai-services'
  params: {
    managedIdentityResourceId: identity.outputs.resourceId
    name: aiServicesName
    location: location
    publicNetworkAccess: 'Disabled' // 'enabled' or 'disabled'
    deployments: [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4.1-mini'
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

module aiServicesPublic '../modules/ai/ai-foundry.bicep' = {
  name: 'ai-services-public'
  params: {
    managedIdentityResourceId: identity.outputs.resourceId
    name: aiServicesPublicName
    location: location
    publicNetworkAccess: 'Enabled' // 'enabled' or 'disabled'
    deployments: [
      {
        name: 'gpt-4.1-mini'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4.1-mini'
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

module managedEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'managed-environment'
  params: {
    location: location
    appInsightsConnectionString: appInsights.outputs.connectionString
    name: 'aca${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    storages: []
    publicNetworkAccess: 'Disabled'
    infrastructureSubnetId: null
  }
}

module appMcp '../modules/aca/container-app.bicep' = {
  name: 'app-mcp'
  params: {
    location: location
    name: 'aca-mcp-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: appInsights.outputs.connectionString
    definition: {
      settings: []
    }
    ingressTargetPort: 3000
    existingImage: 'ghcr.io/karpikpl/sample-mcp-fastmcp-python:main'
    userAssignedManagedIdentityClientId: identity.outputs.resourceId
    userAssignedManagedIdentityResourceId: identity.outputs.resourceId
    ingressExternal: true
    cpu: '0.25'
    memory: '0.5Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
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

module appOpenAPI '../modules/aca/container-app.bicep' = {
  name: 'app-openapi'
  params: {
    location: location
    name: 'aca-openapi-${resourceToken}'
    workloadProfileName: managedEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    applicationInsightsConnectionString: appInsights.outputs.connectionString
    definition: {
      settings: []
    }
    ingressTargetPort: 3000
    existingImage: 'ghcr.io/karpikpl/wttr-docker:main'
    userAssignedManagedIdentityClientId: identity.outputs.resourceId
    userAssignedManagedIdentityResourceId: identity.outputs.resourceId
    ingressExternal: true
    cpu: '0.25'
    memory: '0.5Gi'
    scaleMaxReplicas: 1
    scaleMinReplicas: 1
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

// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = if (doesFoundrySupportsCrossSubscriptionVnet) {
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
  }
}

module ai_dependencies '../modules/ai-dependencies/standard-dependent-resources.bicep' = if (doesFoundrySupportsCrossSubscriptionVnet) {
  params: {
    location: location
    azureStorageName: 'projstorage${resourceToken}'
    aiSearchName: 'project-search-${resourceToken}'
    cosmosDBName: 'project-cosmosdb-${resourceToken}'

    // AI Search Service parameters

    // Storage Account

    // Cosmos DB Account
  }
}

// Private Endpoint and DNS Configuration
// This module sets up private network access for all Azure services:
// 1. Creates private endpoints in the specified subnet
// 2. Sets up private DNS zones for each service
// 3. Links private DNS zones to the VNet for name resolution
// 4. Configures network policies to restrict access to private endpoints only
module privateEndpointAndDNS '../modules/networking/private-endpoint-and-dns.bicep' = if (doesFoundrySupportsCrossSubscriptionVnet) {
  name: 'private-endpoints-and-dns'
  params: {
    #disable-next-line what-if-short-circuiting
    aiAccountName: aiServices.outputs.FOUNDRY_NAME // AI Services to secure
    #disable-next-line what-if-short-circuiting
    aiSearchName: ai_dependencies!.outputs.AI_SEARCH_NAME // AI Search to secure
    #disable-next-line what-if-short-circuiting
    storageName: ai_dependencies!.outputs.STORAGE_NAME // Storage to secure
    #disable-next-line what-if-short-circuiting
    cosmosDBName: ai_dependencies!.outputs.COSMOS_DB_NAME
    #disable-next-line what-if-short-circuiting
    vnetName: vnet!.outputs.VIRTUAL_NETWORK_NAME // VNet containing subnets
    #disable-next-line what-if-short-circuiting
    peSubnetName: vnet!.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name // Subnet for private endpoints
    suffix: resourceToken // Unique identifier
    #disable-next-line what-if-short-circuiting
    vnetResourceGroupName: vnet!.outputs.VIRTUAL_NETWORK_RESOURCE_GROUP
    #disable-next-line what-if-short-circuiting
    vnetSubscriptionId: vnet!.outputs.VIRTUAL_NETWORK_SUBSCRIPTION_ID // Subscription ID for the VNet
    #disable-next-line what-if-short-circuiting
    cosmosDBSubscriptionId: ai_dependencies!.outputs.COSMOS_DB_SUBSCRIPTION_ID // Subscription ID for Cosmos DB
    #disable-next-line what-if-short-circuiting
    cosmosDBResourceGroupName: ai_dependencies!.outputs.COSMOS_DB_RESOURCE_GROUP_NAME // Resource Group for Cosmos DB
    #disable-next-line what-if-short-circuiting
    aiSearchSubscriptionId: ai_dependencies!.outputs.AI_SEARCH_SUBSCRIPTION_ID // Subscription ID for AI Search Service
    #disable-next-line what-if-short-circuiting
    aiSearchResourceGroupName: ai_dependencies!.outputs.AI_SEARCH_RESOURCE_GROUP_NAME // Resource Group for AI Search Service
    #disable-next-line what-if-short-circuiting
    storageAccountResourceGroupName: ai_dependencies!.outputs.STORAGE_RESOURCE_GROUP_NAME // Resource Group for Storage Account
    #disable-next-line what-if-short-circuiting
    storageAccountSubscriptionId: ai_dependencies!.outputs.STORAGE_SUBSCRIPTION_ID // Subscription ID for Storage Account
  }
}
