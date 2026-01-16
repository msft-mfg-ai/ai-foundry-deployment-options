// This bicep files deploys one resource group with the following resources:
// 1. The AI Foundry dependencies, such as VNet and
//    private endpoints for AI Search, Azure Storage and Cosmos DB
// 2. The AI Foundry itself
// 3. Two AI Projects with the capability hosts - in Foundry Standard mode
targetScope = 'resourceGroup'

param location string = resourceGroup().location
@secure()
param openAiApiKey string
param openAiApiBase string

var valid_config = empty(openAiApiKey) || empty(openAiApiBase)
  ? fail('Both OPENAI_API_KEY and OPENAI_API_BASE environment variables must be set.')
  : true

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

module identity '../modules/iam/identity.bicep' = {
  name: 'project-identity'
  params: {
    identityName: 'app-${resourceToken}-project-identity'
    location: location
  }
}

module foundry_identity '../modules/iam/identity.bicep' = {
  name: 'foundry-identity-deployment'
  params: {
    identityName: 'foundry-${resourceToken}-identity'
    location: location
  }
}


// vnet doesn't have to be in the same RG as the AI Services
// each foundry needs it's own delegated subnet, projects inside of one Foundry share the subnet for the Agents Service
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    vnetName: 'project-vnet-${resourceToken}'
    location: location
    extraAgentSubnets: 1
  }
}

module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
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
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
    location: location
  }
}

module keyVault '../modules/kv/key-vault.bicep' = {
  name: 'key-vault-deployment-for-foundry'
  params: {
    tags: {}
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
    managedIdentityResourceId: foundry_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    name: 'ai-foundry-${resourceToken}'
    location: location
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId // Use the first agent subnet
    deployments: [] // no models
    keyVaultResourceId: keyVault.outputs.KEY_VAULT_RESOURCE_ID
  }
}

module identities '../modules/iam/identity.bicep' = [
  for i in range(1, 3): {
    name: 'ai-project-${i}-identity-${resourceToken}'
    params: {
      identityName: 'ai-project-${i}-identity-${resourceToken}'
      location: location
    }
  }
]

@batchSize(1)
module projects '../modules/ai/ai-project-with-caphost.bicep' = [
  for i in range(1, 3): {
    name: 'ai-project-${i}-with-caphost-${resourceToken}'
    params: {
      foundryName: foundry.outputs.FOUNDRY_NAME
      location: location
      projectId: i
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module project4 '../modules/ai/ai-project-with-caphost.bicep' = {
  name: 'ai-project-4-with-caphost-${resourceToken}'
  params: {
    foundryName: foundry.outputs.FOUNDRY_NAME
    location: location
    projectId: 4
    aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: null
    managedIdentityResourceId: null
  }
}

module dnsAca 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'dns-aca'
  params: {
    name: 'privatelink.${location}.azurecontainerapps.io'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
      }
    ]
  }
}

module dnsPostgress 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'dns-postgress'
  params: {
    name: 'privatelink.postgres.database.azure.com'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
      }
    ]
  }
}

module liteLlm '../modules/litellm/lite-llm.bicep' = {
  name: 'lite-llm-deployment-${resourceToken}'
  params: {
    location: location
    resourceToken: resourceToken
    identityResourceId: identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    virtualNetworkResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    acaSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.extraAgentSubnets[0].resourceId
    keyVaultDnsZoneResourceId: ai_dependencies.outputs.DNS_ZONES['privatelink.vaultcore.azure.net']!.resourceId
    postgressDnsZoneResourceId: dnsPostgress.outputs.resourceId
    openAiApiKey: openAiApiKey
    openAiApiBase: openAiApiBase
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    litlLlmPublicFqdn: 'http://${publicIpAddress.outputs.ipAddress}'
    liteLlmConfigYaml: '''
model_list:
  - model_name: azure-gpt-4.1-mini
    litellm_params:
      model: azure/gpt-4.1-mini
      api_base: os.environ/AZURE_API_BASE # runs os.getenv("AZURE_API_BASE")
      api_key: os.environ/AZURE_API_KEY # runs os.getenv("AZURE_API_KEY")
      api_version: "2025-04-14"
  - model_name: azure-gpt-5-mini
    litellm_params:
      model: azure/gpt-5-mini
      api_base: os.environ/AZURE_API_BASE # runs os.getenv("AZURE_API_BASE")
      api_key: os.environ/AZURE_API_KEY # runs os.getenv("AZURE_API_KEY")
      api_version: "2025-08-07"
  - model_name: azure-o3-mini
    litellm_params:
      model: azure/o3-mini
      api_base: os.environ/AZURE_API_BASE # runs os.getenv("AZURE_API_BASE")
      api_key: os.environ/AZURE_API_KEY # runs os.getenv("AZURE_API_KEY")
      api_version: "2025-01-31"

general_settings:
  store_model_in_db: true
  store_prompts_in_spend_logs: true

litellm_settings:
  drop_params: true
  callbacks: ["otel"]  # list of callbacks - runs on success and failure    

callback_settings:
  otel:
    message_logging: True
    '''
    modelsStatic: [
      {
        name: 'azure-gpt-4.1-mini'
        properties: {
          model: {
            name: 'gpt-4.1-mini'
            version: '2025-01-01-preview'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'azure-gpt-5-mini'
        properties: {
          model: {
            name: 'gpt-5-mini'
            version: '2025-04-01-preview'
            format: 'OpenAI'
          }
        }
      }
      {
        name: 'azure-o3-mini'
        properties: {
          model: {
            name: 'o3-mini'
            version: '2025-01-01-preview'
            format: 'OpenAI'
          }
        }
      }
    ]
    // litellm_settings:
    //     enable_azure_ad_token_refresh: true
    // https://docs.litellm.ai/docs/providers/azure#azure-ad-token-refresh---defaultazurecredential
  }
}

module publicIpAddress 'br/public:avm/res/network/public-ip-address:0.10.0' = {
  params: {
    // Required parameters
    name: 'app-gateway-${resourceToken}-public-ip'
    // Non-required parameters
    location: location
    availabilityZones: []
  }
}

module acaAppGateway '../modules/appgtw/application-gateway.bicep' = {
  name: 'aca-app-gateway-deployment-${resourceToken}'
  params: {
    location: location
    name: 'app-gateway-${resourceToken}'
    applicationFqdn: liteLlm.outputs.liteLlmAcaFqdn
    applicationGatewaySubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.appGwSubnet.resourceId
    acaName: 'aca${resourceToken}'
    publicIpResourceId: publicIpAddress.outputs.resourceId
    tags: {
      CostControl:'Ignore'
      'hidden-title':'LiteLLM public gateway'
    }
  }
}

output FOUNDRY_PROJECTS_CONNECTION_STRINGS string[] = [for i in range(1, 3): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING]
output FOUNDRY_PROJECT_NAMES string[] = [for i in range(1, 3): projects[i - 1].outputs.FOUNDRY_PROJECT_NAME]
output CONFIG_VALIDATION_RESULT bool = valid_config
