// ============================================================================
// ai-gateway-tools — APIM StandardV2 + API Center as an MCP registry
// ----------------------------------------------------------------------------
// Focused sample that demonstrates using Azure API Management as a
// centralised registry for MCP (Model Context Protocol) servers, with
// Azure API Center on top for API discovery / governance.
//
// What it deploys (single resource group):
//   - VNet with a private endpoint subnet + an APIM v2 injection subnet
//   - Log Analytics workspace + Application Insights
//   - APIM (StandardV2 SKU) — VNet-integrated
//   - Azure API Center linked to the APIM instance
//   - Public MCP servers registered as `type: 'mcp'` APIs on APIM
//   - Optional private (behind PE) MCP servers — one PE per target resource
//
// This sample intentionally does NOT deploy an AI Foundry account. It is
// the smallest possible surface for "APIM + API Center as an MCP hub".
//
// Inspired by Komatsu/ai-landing-zone-01 (2-apim stage) — extracted here as
// a self-contained, single-region deployment.
// ============================================================================
targetScope = 'resourceGroup'

import { publicMcpType, privateMcpType } from '../modules/apim/mcp-tools.bicep'

param location string = resourceGroup().location

@description('Whether APIM should be reachable from the public internet. Set to false to make APIM VNet-internal only. StandardV2 supports both modes.')
param apimPublicEnabled bool = true

@description('Public MCP servers to register. Defaults to a curated list of public MCPs; set your own list or empty [] to disable.')
param publicMcps publicMcpType[] = [
  {
    name: 'ms-learn'
    displayName: 'Microsoft Learn Docs MCP'
    uri: 'https://learn.microsoft.com/api/mcp'
  }
  {
    name: 'azure-rest-api'
    displayName: 'Azure REST API specs (gitmcp)'
    uri: 'https://gitmcp.io/Azure/azure-rest-api-specs'
  }
  {
    name: 'github'
    displayName: 'GitHub MCP (public)'
    uri: 'https://api.githubcopilot.com/mcp/'
  }
  {
    name: 'deepwiki'
    displayName: 'DeepWiki MCP'
    uri: 'https://mcp.deepwiki.com/mcp'
  }
  {
    name: 'context7'
    displayName: 'Context7 MCP'
    uri: 'https://mcp.context7.com/mcp'
  }
]

@description('Private MCP servers to register. For each entry, a private endpoint is created against the target resource with the requested DNS zone. Leave empty to skip PE creation.')
param privateMcps privateMcpType[] = []

var tags = {
  'created-by': 'option-ai-gateway-tools'
  'hidden-title': 'APIM StandardV2 + API Center as MCP registry'
  SecurityControl: 'Ignore'
}

var resourceToken = toLower(uniqueString(resourceGroup().id, location))

// --------------------------------------------------------------------------------------------------------------
// -- VNet -----------------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
// Even when APIM is public we still need a VNet to host the private
// endpoints for the private MCP servers, and StandardV2 supports VNet
// integration for outbound reachability to those PEs.
module vnet '../modules/networking/vnet.bicep' = {
  name: 'vnet-${resourceToken}'
  params: {
    tags: tags
    location: location
    vnetName: 'ai-gateway-tools-vnet-${resourceToken}'
    vnetAddressPrefix: '192.168.0.0/20'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- Log Analytics + App Insights -------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module logAnalytics '../modules/monitor/loganalytics.bicep' = {
  name: 'log-analytics-${resourceToken}'
  params: {
    tags: tags
    location: location
    newLogAnalyticsName: 'log-${resourceToken}'
    newApplicationInsightsName: 'appi-${resourceToken}'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- APIM StandardV2 -------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
// StandardV2 supports VNet integration and `type: 'mcp'` APIs which the
// apim-streamable-mcp module produces. No AI-model backends here — this
// APIM instance is used purely to front MCP servers.
module apim '../modules/apim/v2/apim.bicep' = {
  name: 'apim-${resourceToken}'
  params: {
    apiManagementName: 'apim-tools-${resourceToken}'
    location: location
    tags: tags
    apimSku: 'Standardv2'
    lawId: logAnalytics.outputs.LOG_ANALYTICS_WORKSPACE_RESOURCE_ID
    appInsightsId: logAnalytics.outputs.APPLICATION_INSIGHTS_RESOURCE_ID
    appInsightsInstrumentationKey: logAnalytics.outputs.APPLICATION_INSIGHTS_INSTRUMENTATION_KEY
    virtualNetworkType: apimPublicEnabled ? 'External' : 'Internal'
    subnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.apimv2Subnet.resourceId
    publicNetworkAccess: apimPublicEnabled ? 'Enabled' : 'Disabled'
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- MCP tools registration (public + private via PE) ----------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
module mcpTools '../modules/apim/mcp-tools.bicep' = {
  name: 'mcp-tools-${resourceToken}'
  params: {
    tags: tags
    location: location
    apimServiceName: apim.outputs.name
    apimAppInsightsLoggerId: apim.outputs.appInsightsLoggerId
    vnetResourceId: vnet.outputs.VIRTUAL_NETWORK_RESOURCE_ID
    peSubnetResourceId: vnet.outputs.VIRTUAL_NETWORK_SUBNETS.peSubnet.resourceId
    publicMcps: publicMcps
    privateMcps: privateMcps
  }
}

// --------------------------------------------------------------------------------------------------------------
// -- API Center -------------------------------------------------------------------------------------------------
// --------------------------------------------------------------------------------------------------------------
// Linked to the APIM instance — every API registered on APIM (including
// the MCP tools above) is auto-imported into the API Center inventory.
module apiCenter '../modules/apim/api-center.bicep' = {
  name: 'api-center-${resourceToken}'
  params: {
    tags: tags
    location: location
    name: 'apic-tools-${resourceToken}'
    apimResourceId: apim.outputs.id
    sku: 'Free'
  }
  dependsOn: [
    mcpTools
  ]
}

output APIM_NAME string = apim.outputs.name
output APIM_RESOURCE_ID string = apim.outputs.id
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output API_CENTER_NAME string = apiCenter.outputs.apiCenterName
output API_CENTER_RESOURCE_ID string = apiCenter.outputs.apiCenterId
output REGISTERED_MCP_COUNT int = mcpTools.outputs.registeredMcpCount
output PUBLIC_MCP_URLS string[] = mcpTools.outputs.publicMcpUrls
output PRIVATE_MCP_URLS string[] = mcpTools.outputs.privateMcpUrls
output RESOURCE_GROUP string = resourceGroup().name
