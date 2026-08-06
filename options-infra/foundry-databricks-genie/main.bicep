// Deploys a single VNet-injected Foundry project and a VNet-injected
// Azure Databricks workspace prepared for the Genie One managed MCP server.
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('VNet address space. /20 leaves room for Foundry and Databricks dedicated subnets.')
param vnetAddressPrefix string = '192.168.0.0/20'

@description('Name of the prompt agent created by the optional azd postprovision hook.')
param genieAgentName string = 'agent-databricks-genie-one'

@allowed([
  'trial'
  'standard'
  'premium'
])
@description('Azure Databricks workspace SKU. Premium is recommended for Genie and Unity Catalog.')
param databricksPricingTier string = 'premium'

var tags = {
  'created-by': 'foundry-databricks-genie'
  'hidden-title': 'Foundry Standard with Azure Databricks Genie One'
}
var resourceToken = toLower(uniqueString(resourceGroup().id, location))
var vnetName = 'foundry-databricks-vnet-${resourceToken}'
var projectName = 'databricks-genie-project'
var modelDeploymentName = 'gpt-5.2'

module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet'
  params: {
    tags: tags
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
  }
}

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
  }
}

module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-analytics-${resourceToken}'
    newApplicationInsightsName: 'app-insights-${resourceToken}'
  }
}

module foundry '../modules/ai/ai-foundry.bicep' = {
  name: 'foundry'
  params: {
    tags: tags
    location: location
    managedIdentityResourceId: ''
    name: 'ai-foundry-${resourceToken}'
    publicNetworkAccess: 'Enabled'
    agentSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.agentSubnet.resourceId
    deployments: [
      {
        name: modelDeploymentName
        properties: {
          model: {
            format: 'OpenAI'
            name: modelDeploymentName
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

module projectIdentity '../modules/iam/identity.bicep' = {
  name: 'project-identity'
  params: {
    tags: tags
    location: location
    identityName: 'id-${projectName}-${resourceToken}'
  }
}

module project '../modules/ai/ai-project-with-caphost.bicep' = {
  name: 'project-with-caphost'
  params: {
    tags: tags
    location: location
    foundryName: foundry.outputs.FOUNDRY_NAME
    project_name: projectName
    project_description: 'Foundry project connected to Azure Databricks Genie One'
    display_name: 'Azure Databricks Genie One'
    aiDependencies: aiDependencies.outputs.AI_DEPENDECIES
    existingAiResourceId: null
    managedIdentityResourceId: projectIdentity.outputs.MANAGED_IDENTITY_RESOURCE_ID
    appInsightsResourceId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
  }
}

module databricks '../modules/databricks/databricks-workspace-vnet-injected.bicep' = {
  name: 'databricks-workspace'
  params: {
    tags: tags
    location: location
    workspaceName: 'dbw-${resourceToken}'
    vnetName: vnetName
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    privateEndpointSubnetId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    blobPrivateDnsZoneId: aiDependencies.outputs.DNS_ZONES['privatelink.blob.core.windows.net']!.resourceId
    publicSubnetPrefix: cidrSubnet(vnetAddressPrefix, 24, 9)
    privateSubnetPrefix: cidrSubnet(vnetAddressPrefix, 24, 10)
    pricingTier: databricksPricingTier
  }
}

output FOUNDRY_PROJECT_CONNECTION_STRING string = project.outputs.FOUNDRY_PROJECT_CONNECTION_STRING
output FOUNDRY_PROJECT_NAME string = project.outputs.FOUNDRY_PROJECT_NAME
output FOUNDRY_NAME string = foundry.outputs.FOUNDRY_NAME
output AZURE_OPENAI_CHAT_DEPLOYMENT_NAME string = modelDeploymentName
output GENIE_AGENT_NAME string = genieAgentName
output DATABRICKS_WORKSPACE_NAME string = databricks.outputs.WORKSPACE_NAME
output DATABRICKS_WORKSPACE_ID string = databricks.outputs.WORKSPACE_NUMERIC_ID
output DATABRICKS_WORKSPACE_URL string = databricks.outputs.WORKSPACE_URL
output DATABRICKS_GENIE_ONE_MCP_URL string = databricks.outputs.GENIE_ONE_MCP_URL
output DATABRICKS_NAT_PUBLIC_IP string = databricks.outputs.NAT_PUBLIC_IP
output DATABRICKS_ACCESS_CONNECTOR_ID string = databricks.outputs.ACCESS_CONNECTOR_ID
output DATABRICKS_MANAGED_STORAGE_URL string = databricks.outputs.MANAGED_STORAGE_URL
