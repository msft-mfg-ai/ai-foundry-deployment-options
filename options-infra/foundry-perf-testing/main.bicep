// options-infra/foundry-perf-testing/main.bicep
//
// Baseline infra for three-way agent perf comparison:
//   1. Prompt agent (declarative Foundry agent)
//   2. Hosted agent (C# container inside Foundry)
//   3. Custom agent (same C# code on ACA)
//
// Design mirrors `foundry-byo-vnet-no-dependencies`:
//   - Public Foundry account with VNet-injected agent subnet
//   - Single model deployment (gpt-5-mini)
//   - Project capability host WITHOUT BYO storage/search/cosmos
// Adds:
//   - ACA environment (separate subnet, delegated to Microsoft.App/environments)
//   - ACR for hosted-agent + custom-agent + MCP images
//   - Shared UAMI used by the custom-agent ACA app
//   - Log Analytics + Application Insights (shared across all three variants)

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Chat model to deploy for the perf comparison. All three agent variants use this same deployment.')
param chatModelName string = 'gpt-5-mini'

@description('Chat model version. Kept as a parameter because gpt-5-mini has multiple public versions.')
param chatModelVersion string = '2025-08-07'

@description('GlobalStandard capacity (in K TPM units).')
param chatModelCapacity int = 50

var tags = {
  'created-by': 'foundry-perf-testing'
  'hidden-title': 'Foundry perf comparison - Prompt vs Hosted vs Custom'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// ── VNet: reuse the full vnet.bicep so we get `acaSubnet` alongside agent + PE. ─
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'perf-vnet-${resourceToken}'
    vnetAddressPrefix: '192.168.0.0/20'
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

// ── Foundry account: public NW access, VNet-injected agent subnet, one model. ──
module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: '' // System-assigned identity
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: [
      {
        name: chatModelName
        properties: {
          model: {
            format: 'OpenAI'
            name: chatModelName
            version: chatModelVersion
          }
        }
        sku: {
          name: 'GlobalStandard'
          capacity: chatModelCapacity
        }
      }
    ]
  }
}

module project_identity '../modules/iam/identity.bicep' = {
  name: 'ai-project-identity-${resourceToken}'
  params: {
    tags: tags
    location: location
    identityName: 'ai-project-identity-${resourceToken}'
  }
}

module project '../modules/ai/ai-project.bicep' = {
  name: 'ai-project-${resourceToken}'
  params: {
    tags: tags
    location: location
    foundry_name: foundry.outputs.FOUNDRY_NAME
    project_name: 'ai-project-${resourceToken}-1'
    project_description: 'Perf comparison project ${resourceToken}'
    display_name: 'Perf comparison project ${resourceToken}'
    managedIdentityResourceId: project_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    // Account-level caphost is created automatically with VNet injection.
    createAccountCapabilityHost: false
  }
}

// Project capability host WITHOUT BYO storage/search/cosmos — matches the
// `foundry-byo-vnet-no-dependencies` baseline.
module caphost '../modules/ai/add-project-capability-host.bicep' = {
  name: 'caphost-${resourceToken}'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectName: project.outputs.FOUNDRY_PROJECT_NAME
  }
}

// ── ACR (Premium, public-enabled for simplicity of azd deploy from the CLI). ───
module containerRegistry '../modules/aml/container-registry.bicep' = {
  name: 'container-registry'
  params: {
    tags: tags
    location: location
    name: 'acr${resourceToken}'
    logAnalyticsWorkspaceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    publicAccessEnabled: true
    principalIdsForPullPermission: [
      // Foundry ACCOUNT system-assigned MI — used by the Foundry platform to
      // pull hosted-agent images at agent activation time. This is the
      // critical grant for `host: azure.ai.agent` deploys.
      foundry.outputs.FOUNDRY_PRINCIPAL_ID
      // Project UAMI — used by the project runtime for other operations.
      project_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      // Custom-agent MI on ACA — pulls its own image.
      app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    ]
  }
}

// ── ACA environment for the MCP server + custom-agent container. ───────────────
module acaEnvironment '../modules/aca/container-app-environment.bicep' = {
  name: 'aca-environment-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'aca-env-${resourceToken}'
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    infrastructureSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.acaSubnet.resourceId
    appInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    publicNetworkAccess: 'Enabled'
  }
}

// ── Shared UAMI for the custom-agent ACA app. ─────────────────────────────────
module app_identity '../modules/iam/identity.bicep' = {
  name: 'app-identity-${resourceToken}'
  params: {
    tags: tags
    location: location
    identityName: 'app-identity-${resourceToken}'
  }
}

// Custom agent bypasses Foundry Responses — it calls the account's /openai/v1/
// endpoint directly, so its MI needs Cognitive Services OpenAI User at ACCOUNT
// scope (memory: foundry hosted-agent BYOK — same role applies here).
module app_identity_cog_role '../modules/iam/role-assignment-cognitiveServices.bicep' = {
  name: 'app-identity-cog-${resourceToken}'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    principalId: app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    roleName: 'Cognitive Services OpenAI User'
  }
}

// Azure AI User at project scope — needed for AIProjectClient calls.
module app_identity_project_role '../modules/iam/role-assignment-foundryProject.bicep' = {
  name: 'app-identity-project-${resourceToken}'
  params: {
    accountName: foundry.outputs.FOUNDRY_NAME
    projectName: project.outputs.FOUNDRY_PROJECT_NAME
    principalId: app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID
    roleName: 'Azure AI User'
  }
}

// ── ACA container apps (initial deploy with placeholder image; azd deploy updates). ──
//
// The `azd-service-name` tag on each app matches the `services` key in
// azure.yaml, which is how azd finds them to push new images.
module mcp_server_app '../modules/aca/container-app.bicep' = {
  name: 'aca-mcp-server-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'mcp-server'
    definition: {
      settings: [
        {
          name: 'PORT'
          value: '8000'
        }
        {
          name: 'OTEL_SERVICE_NAME'
          value: 'mcp-server'
        }
      ]
    }
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    userAssignedManagedIdentityClientId: app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressTargetPort: 8000
    ingressExternal: true
    cpu: '0.5'
    memory: '1Gi'
    scaleMinReplicas: 1
    scaleMaxReplicas: 3
    workloadProfileName: acaEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    containerAppsEnvironmentResourceId: acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 8000
        }
      }
    ]
  }
}

module support_agent_custom_app '../modules/aca/container-app.bicep' = {
  name: 'aca-support-agent-custom-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'support-agent-custom'
    definition: {
      settings: [
        {
          name: 'ASPNETCORE_URLS'
          value: 'http://+:8080'
        }
        {
          name: 'FOUNDRY_ACCOUNT_ENDPOINT'
          value: 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com'
        }
        {
          name: 'FOUNDRY_PROJECT_ENDPOINT'
          value: 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${project.outputs.FOUNDRY_PROJECT_NAME}'
        }
        {
          name: 'CHAT_MODEL_DEPLOYMENT'
          value: chatModelName
        }
        {
          name: 'MCP_SERVER_URL'
          // ACA app FQDN — the mcp-server app publishes its own FQDN as output
          // but referencing it here would create a module cycle; instead we
          // construct it from the env default domain. FastMCP mount at /mcp.
          value: 'https://mcp-server.${acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN}/mcp'
        }
        {
          name: 'OTEL_SERVICE_NAME'
          value: 'support-agent-custom'
        }
      ]
    }
    applicationInsightsConnectionString: logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
    userAssignedManagedIdentityClientId: app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
    userAssignedManagedIdentityResourceId: app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    ingressTargetPort: 8080
    ingressExternal: true
    cpu: '1.0'
    memory: '2Gi'
    // Pin min-replicas=1 so cold-start doesn't pollute the perf comparison.
    scaleMinReplicas: 1
    scaleMaxReplicas: 5
    workloadProfileName: acaEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME
    containerAppsEnvironmentResourceId: acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
    containerRegistryLoginServer: containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
    probes: [
      {
        type: 'Readiness'
        httpGet: {
          path: '/health'
          port: 8080
        }
      }
    ]
  }
}

// ── Outputs (consumed by azure.yaml / azd env / perf harness) ──────────────────
output PROJECT_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${project.outputs.FOUNDRY_PROJECT_NAME}'
output FOUNDRY_PROJECT_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com/api/projects/${project.outputs.FOUNDRY_PROJECT_NAME}'
output FOUNDRY_ACCOUNT_ENDPOINT string = 'https://${foundry.outputs.FOUNDRY_NAME}.services.ai.azure.com'
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output AZURE_AI_PROJECT_ID string = '${foundry.outputs.FOUNDRY_RESOURCE_ID}/projects/${project.outputs.FOUNDRY_PROJECT_NAME}'
output AZURE_AI_PROJECT_NAME string = project.outputs.FOUNDRY_PROJECT_NAME
output CHAT_MODEL string = chatModelName
output RESOURCE_GROUP string = resourceGroup().name

output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_NAME
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.AZURE_CONTAINER_REGISTRY_LOGIN_SERVER
output AZURE_CONTAINER_APPS_ENVIRONMENT_ID string = acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_ID
output AZURE_CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN string = acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN
output AZURE_CONTAINER_APPS_WORKLOAD_PROFILE_NAME string = acaEnvironment.outputs.CONTAINER_APPS_WORKLOAD_PROFILE_NAME

output APP_IDENTITY_CLIENT_ID string = app_identity.outputs.MANAGED_IDENTITY_CLIENT_ID
output APP_IDENTITY_RESOURCE_ID string = app_identity.outputs.MANAGED_IDENTITY_RESOURCE_ID
output APP_IDENTITY_PRINCIPAL_ID string = app_identity.outputs.MANAGED_IDENTITY_PRINCIPAL_ID

output APPLICATIONINSIGHTS_CONNECTION_STRING string = logAnalytics.outputs.APPLICATION_INSIGHTS_CONNECTION_STRING
output LOG_ANALYTICS_WORKSPACE_ID string = logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID

output MCP_SERVER_URL string = 'https://mcp-server.${acaEnvironment.outputs.CONTAINER_APPS_ENVIRONMENT_DEFAULT_DOMAIN}/mcp'
output SERVICE_MCP_SERVER_ENDPOINT string = mcp_server_app.outputs.CONTAINER_APP_FQDN
output SERVICE_SUPPORT_AGENT_CUSTOM_ENDPOINT string = support_agent_custom_app.outputs.CONTAINER_APP_FQDN
