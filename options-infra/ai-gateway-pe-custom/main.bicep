// This bicep file deploys one resource group with the following resources:
// 1. Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. Foundry account and projects
// 3. APIM as AI Gateway to allow Foundry Agent Service to use models from APIM
// 4. Projects with capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'

param location string = resourceGroup().location
param projectsCount int = 3
param apiServices apiType[] = [] // Array of MCP service definitions
param apimPublicEnabled bool = false
param openAiLocation string = resourceGroup().location

var tags = {
  'created-by': 'option-ai-gateway-custom'
  'hidden-title': 'Foundry - APIM v2 Standard with PE Custom'
  SecurityControl: 'Ignore'
}
var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module openai_with_models '../modules/ai/ai-foundry.bicep' = {
  name: 'azure-openai'
  params: {
    location: openAiLocation
    tags: tags
    name: 'openai-${resourceToken}'
    kind: 'OpenAI'
    publicNetworkAccess: 'Disabled'
    deployments: [
      {
        name: 'test-gpt-4.1'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-4.1'
            version: '2025-04-14'
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: 20
        }
      }
      {
        name: 'test-gpt-5.2'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5.2'
            version: '2025-12-11'
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

// Private endpoint for external OpenAI
module openai_private_endpoint '../modules/networking/ai-pe-dns.bicep' = {
  name: 'openai-private-endpoint-and-dns-deployment'
  params: {
    tags: tags
    location: location
    aiAccountName: openai_with_models.outputs.FOUNDRY_NAME
    peSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    resourceToken: resourceToken
    existingDnsZones: ai_dependencies.outputs.DNS_ZONES
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

module ai_gateway '../modules/apim/ai-gateway-pe.bicep' = {
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
    staticModels: [
      {
        name: 'test-gpt-4.1'
        properties: {
          model: {
            name: 'gpt-4.1'
            version: '2025-01-01-preview'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'test-gpt-5.2'
        properties: {
          model: {
            format: 'OpenAI'
            name: 'gpt-5.2'
            version: '2025-12-11'
          }
        }
      }
    ]
    aiServicesConfig: [
      {
        name: openai_with_models.outputs.FOUNDRY_NAME
        resourceId: openai_with_models.outputs.FOUNDRY_RESOURCE_ID
        endpoint: openai_with_models.outputs.FOUNDRY_ENDPOINT
        location: openAiLocation
      }
    ]
  }
}

module apim_role_assignment '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: 'apim-role-assignment-deployment-${resourceToken}'
  params: {
    accountName: openai_with_models.outputs.FOUNDRY_NAME
    principalId: ai_gateway.outputs.apimPrincipalId
    roleName: 'Cognitive Services User'
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
