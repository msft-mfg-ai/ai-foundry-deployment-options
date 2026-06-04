// foundry-byo-vnet-firewall
// ============================================================================
// Clone of `foundry-two-projects` that routes agent-subnet + pe-subnet egress
// through an Azure Firewall (Basic SKU by default). Uses the standard
// `modules/networking/vnet.bicep` and `modules/networking/firewall.bicep`
// modules — no inline VNet/NSG/subnet definitions.
//
// Order of operations (avoids the chicken-and-egg between subnet ↔ firewall):
//   1. Empty route table is created.
//   2. `vnet.bicep` creates the VNet with all subnets — agent-subnet and
//      pe-subnet reference the empty route table; AzureFirewallSubnet and
//      AzureFirewallManagementSubnet are added via the new firewall*Prefix
//      params.
//   3. `firewall.bicep` deploys the firewall using the AzureFirewall* subnet
//      IDs, then populates the existing route table with `0.0.0.0/0` plus
//      the bundled-default agent CIDR route — using `createRouteTable: false`.
// All bundled-default firewall rules (FQDN allowlist, deny port 80) live in
// `firewall.bicep` and are applied automatically.

targetScope = 'resourceGroup'

import { apiType } from '../modules/apps/apps-private-link.bicep'

param location string = resourceGroup().location
param projectsCount int = 1
param apiServices apiType[] = [] // External MCP/OpenAPI services

// Start dev tunnel with: devtunnel host -p 3000 --allow-anonymous
// Start proxy with NPX that proxies calls back to Foundry
@description('Dev tunnel URL - received from  devtunnel host')
param devTunnelUrl string?

var tags = {
  'created-by': 'foundry-byo-vnet-firewall'
  'hidden-title': 'Foundry Standard - BYO VNet + Azure Firewall egress'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// 1. Empty route table — populated by the firewall module once the firewall
//    private IP is known. Created up-front so agent/pe subnets can reference
//    it at creation time.
resource routeTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'foundry-fw-rt'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

// 2. VNet — uses the shared vnet.bicep module with optional firewall subnet
//    + route table params (added by this change). All other subnets and NSGs
//    come from the module's defaults; subnet prefixes for the firewall are
//    auto-computed by vnet.bicep to avoid overlap with the standard subnets.
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: 'project-vnet-${resourceToken}'
    createFirewallSubnets: true
    routeTableResourceId: routeTable.id
  }
}

// 3. Log Analytics workspace — created BEFORE the firewall so its workspace
//    ID can be wired into the firewall's diagnostic settings. Without this,
//    Azure Firewall emits no logs by default.
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics'
    newApplicationInsightsName: 'app-insights'
  }
}

// 4. Firewall — deploys into the AzureFirewall subnets, populates the
//    existing route table (createRouteTable=false). Uses bundled default
//    application + network rule collections (agent FQDN allowlist + deny
//    port 80), so no rule params are passed here. Diagnostic setting routes
//    AZFW* logs into the Log Analytics workspace above.
module firewall '../modules/networking/firewall.bicep' = {
  name: 'firewall'
  params: {
    location: location
    tags: tags
    namePrefix: 'foundry-fw'
    firewallSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_AZURE_FIREWALL_SUBNET_RESOURCE_ID
    firewallManagementSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_AZURE_FIREWALL_MANAGEMENT_SUBNET_RESOURCE_ID
    createRouteTable: false
    existingRouteTableName: routeTable.name
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    agentSubnetPrefix: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.prefix
  }
}

// ---------------------------------------------------------------------------
// Foundry stack — unchanged from foundry-two-projects.
// ---------------------------------------------------------------------------
module ai_dependencies '../modules/ai/ai-dependencies-with-dns.bicep' = {
  name: 'ai-dependencies-with-dns'
  params: {
    tags: tags
    location: location
    peSubnetName: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.name
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    resourceToken: resourceToken
    aiServicesName: ''
    aiAccountNameResourceGroupName: ''
  }
}

var deployments = [
  {
    name: 'gpt-5.2'
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

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry-deployment'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: ''
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: deployments
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

// this is usually not required but this time project identity is used to in model gateway connection with auth type 'ProjectManagedIdentity'
module project_role_assignments '../modules/iam/role-assignment-cognitiveServices.bicep' = [
  for i in range(1, projectsCount): {
    name: 'project-${i}-role-assignment-${resourceToken}'
    params: {
      accountName: foundry.outputs.FOUNDRY_NAME
      principalId: project_identities[i - 1].outputs.MANAGED_IDENTITY_PRINCIPAL_ID
      roleName: 'Cognitive Services OpenAI User'
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
      project_description: 'AI Project ${i} ${resourceToken}'
      display_name: 'AI Project ${i} ${resourceToken}'
      projectId: i
      project_name: projectNames[i - 1]
      aiDependencies: ai_dependencies.outputs.AI_DEPENDECIES
      existingAiResourceId: null
      managedIdentityResourceId: project_identities[i - 1].outputs.MANAGED_IDENTITY_RESOURCE_ID
      appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    }
  }
]

module mcp_apis '../modules/apps/apps-private-link.bicep' = {
  name: 'mcp-apis-private-link-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    aiFoundryName: foundry.outputs.FOUNDRY_NAME
    externalApis: apiServices
  }
}

module modelGatewayConnectionStatic '../modules/ai/connection-modelgateway-static.bicep' = [
  for projectName in projectNames: if (!empty(devTunnelUrl)) {
    name: '${projectName}-connection-gateway'
    params: {
      aiFoundryName: foundry.outputs.FOUNDRY_NAME
      aiFoundryProjectName: projectName
      connectionName: 'devtunnel-${projectName}-static'
      apiKey: 'dummy-key'
      isSharedToAll: false
      gatewayName: 'devtunnel'
      // Aliases must NOT contain slashes to avoid path conflicts
      staticModels: [
        for d in deployments: {
          name: d.name
          properties: {
            model: d.properties.model // drops `sku`, `raiPolicyName`, etc.
          }
        }
      ]
      // No api-version query parameter needed
      inferenceAPIVersion: '2025-03-01-preview'
      targetUrl: devTunnelUrl
      deploymentInPath: 'true'
      authType: 'ProjectManagedIdentity'
    }
    dependsOn: [projects]
  }
]

output project_connection_strings string[] = [
  for i in range(1, projectsCount): projects[i - 1].outputs.FOUNDRY_PROJECT_CONNECTION_STRING
]
output project_names string[] = projectNames
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = 'gpt-5.2'
output OPENAPI_URL string = first(filter(apiServices, api => api.name == 'weather-openapi')).?uri ?? ''
output FIREWALL_PRIVATE_IP string = firewall.outputs.firewallPrivateIp
output ROUTE_TABLE_ID string = firewall.outputs.routeTableResourceId
