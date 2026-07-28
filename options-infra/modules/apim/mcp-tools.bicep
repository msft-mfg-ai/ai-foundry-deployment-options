// ============================================================================
// MCP tools registration in APIM
// ----------------------------------------------------------------------------
// Registers a mix of public and private (behind a private endpoint) MCP
// servers as `type: 'mcp'` APIs on an existing APIM instance. For each
// private MCP, a private endpoint is created against the target resource
// (Container App environment or App Service `sites`) with the appropriate
// private DNS zone linked to the sample VNet.
//
// This module deliberately does NOT touch AI Foundry — it exists to demo
// APIM as an MCP registry and can be used with or without a Foundry account.
// ============================================================================
param apimServiceName string
param apimAppInsightsLoggerId string?

@description('VNet to link created private DNS zones to. Required when privateMcps is non-empty.')
param vnetResourceId string = ''

@description('Subnet to place MCP private endpoints in. Required when privateMcps is non-empty.')
param peSubnetResourceId string = ''

param location string = resourceGroup().location
param tags object = {}

@export()
type publicMcpType = {
  @description('Slug used as the APIM API path (e.g. `ms-learn` → gateway URL `.../ms-learn`).')
  name: string
  @description('Upstream URL of the MCP server (public HTTPS endpoint).')
  uri: string
  @description('Human-readable label rendered in APIM + API Center.')
  displayName: string?
}

@export()
type privateMcpType = {
  @description('Slug used as the APIM API path.')
  name: string
  @description('Full URI (including path) of the upstream MCP endpoint, reached through the PE.')
  uri: string
  @description('Resource ID of the target resource (ACA managedEnvironment or App Service site).')
  resourceId: string
  @description('Private endpoint group ID — `managedEnvironments` for ACA, `sites` for App Service.')
  type: 'sites' | 'managedEnvironments'
  @description('Private DNS zone for the target (e.g. `privatelink.<region>.azurecontainerapps.io` or `privatelink.azurewebsites.net`).')
  dnsZoneName: string
  @description('Human-readable label rendered in APIM + API Center.')
  displayName: string?
}

param publicMcps publicMcpType[] = []
param privateMcps privateMcpType[] = []

// -- DNS zones for private-endpoint MCPs -------------------------------------
var dnsZoneNames = union(map(privateMcps, m => m.dnsZoneName), [])

module mcpDnsZones 'br/public:avm/res/network/private-dns-zone:0.8.1' = [
  for (zoneName, i) in dnsZoneNames: if (!empty(vnetResourceId)) {
    name: 'mcp-dns-${uniqueString(zoneName)}'
    params: {
      tags: tags
      name: zoneName
      virtualNetworkLinks: [
        {
          virtualNetworkResourceId: vnetResourceId
        }
      ]
    }
  }
]

// Build a name → resourceId dictionary of the DNS zones just created so we
// can look them up when wiring each PE zone group.
var dnsZoneRecords = [
  for (zoneName, i) in dnsZoneNames: {
    '${zoneName}': '${resourceGroup().id}/providers/Microsoft.Network/privateDnsZones/${zoneName}'
  }
]
var dnsZoneMap = reduce(dnsZoneRecords, {}, (cur, next) => union(cur, next))

// -- Private endpoints for private MCPs --------------------------------------
module mcpPrivateEndpoints '../networking/private-endpoint.bicep' = [
  for (mcp, i) in privateMcps: {
    name: 'mcp-pe-${mcp.name}'
    params: {
      tags: tags
      location: location
      privateEndpointName: 'pe-mcp-${mcp.name}'
      subnetId: peSubnetResourceId
      targetResourceId: mcp.resourceId
      groupIds: [mcp.type]
      zoneConfigs: [
        {
          name: mcp.dnsZoneName
          privateDnsZoneId: dnsZoneMap[mcp.dnsZoneName]
        }
      ]
    }
    dependsOn: [
      mcpDnsZones
    ]
  }
]

// -- APIM API registrations for public MCPs ----------------------------------
module publicMcpApis './apim-streamable-mcp/api.bicep' = [
  for (mcp, i) in publicMcps: {
    name: 'mcp-public-${mcp.name}'
    params: {
      apimServiceName: apimServiceName
      MCPServiceURL: mcp.uri
      MCPPath: mcp.name
      apimAppInsightsLoggerId: apimAppInsightsLoggerId
    }
  }
]

// -- APIM API registrations for private MCPs ---------------------------------
module privateMcpApis './apim-streamable-mcp/api.bicep' = [
  for (mcp, i) in privateMcps: {
    name: 'mcp-private-${mcp.name}'
    params: {
      apimServiceName: apimServiceName
      MCPServiceURL: mcp.uri
      MCPPath: mcp.name
      apimAppInsightsLoggerId: apimAppInsightsLoggerId
    }
    dependsOn: [
      mcpPrivateEndpoints
    ]
  }
]

output publicMcpUrls string[] = [for (mcp, i) in publicMcps: publicMcpApis[i].outputs.mcpUrl]
output privateMcpUrls string[] = [for (mcp, i) in privateMcps: privateMcpApis[i].outputs.mcpUrl]
output registeredMcpCount int = length(publicMcps) + length(privateMcps)
