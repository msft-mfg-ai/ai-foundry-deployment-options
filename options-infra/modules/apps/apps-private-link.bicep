param location string
param tags object = {}
param vnetResourceId string
param peSubnetResourceId string
param apimServiceName string?
param apimGatewayUrl string?
param aiFoundryName string
param apimAppInsightsLoggerId string?

@export()
type apiType = {
  name: string
  resourceId: string
  type: 'sites' | 'managedEnvironments'
  @description('The DNS zone name for the private endpoint e.g. privatelink.azurewebsites.net or privatelink.<region>.azurecontainerapps.io')
  dnsZoneName: string
  uri: string
  apiType: 'mcp' | 'openapi'
  openApiSpec: string?
}

param externalApis apiType[] = [] // Array of external API definitions

module dnsSites 'br/public:avm/res/network/private-dns-zone:0.8.0' = {
  name: 'dns-sites'
  params: {
    tags: tags
    name: 'privatelink.azurewebsites.net'
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnetResourceId
      }
    ]
  }
}

// find all ACA apps from the external APIs
var acaApps = union(filter(externalApis, (api) => endsWith(api.dnsZoneName, '.azurecontainerapps.io')), [])

// create a map of ACA DNS zone names to their resource IDs
var acaZoneIds = union(
  map(acaApps, (value) => {
    '${value.dnsZoneName}': '${resourceGroup().id}/providers/Microsoft.Network/privateDnsZones/${value.dnsZoneName}'
  }),
  []
)
var acaZoneDict = reduce(acaZoneIds, {}, (cur, next) => union(cur, next))

module dnsAca 'br/public:avm/res/network/private-dns-zone:0.8.0' = [
  for (zoneName, index) in objectKeys(acaZoneDict): {
    name: 'dns-aca-${index}'
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

var dnsZones = union(
  {
    'privatelink.azurewebsites.net': dnsSites.outputs.resourceId
  },
  acaZoneDict
)

// private endpoints for external APIs
module privateEndpoints '../networking/private-endpoint.bicep' = [
  for (api, index) in externalApis: {
    name: 'private-endpoint-${api.name}'
    params: {
      tags: tags
      privateEndpointName: 'pe-${api.name}'
      location: location
      subnetId: peSubnetResourceId // Use the private endpoint subnet
      targetResourceId: api.resourceId
      groupIds: [api.type] // Use the type as group ID
      zoneConfigs: [
        {
          name: api.dnsZoneName
          privateDnsZoneId: dnsZones[api.dnsZoneName]
        }
      ]
    }
    dependsOn: [
      dnsAca
    ]
  }
]

module mcp_apis '../apim/apim-streamable-mcp/api.bicep' = [
  for (api, index) in externalApis: if (!empty(apimServiceName) && api.apiType == 'mcp') {
    name: '${api.name}-mcp-deployment'
    params: {
      apimServiceName: apimServiceName!
      MCPServiceURL: api.uri
      MCPPath: api.name
      apimAppInsightsLoggerId: apimAppInsightsLoggerId
    }
  }
]

module openapi_apis '../apim/v2/openapi-api.bicep' = [
  for (api, index) in externalApis: if (!empty(apimServiceName) && api.apiType == 'openapi') {
    name: '${api.name}-openapi-deployment'
    params: {
      apimServiceName: apimServiceName!
      apiDefinition: api.openApiSpec!
      path: api.name
      serviceURL: api.uri
    }
  }
]

// Reference the AI Foundry account
resource aiFoundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiFoundryName
  scope: resourceGroup()
}

// Create the connection with ApiKey authentication
resource mcpTools 'Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview' = [
  for (api, index) in externalApis: if (api.apiType == 'mcp' && !empty(aiFoundryName) && !empty(apimGatewayUrl)) {
    name: 'MC-${api.name}'
    parent: aiFoundry
    properties: {
      category: 'RemoteTool'
      group: 'GenericProtocol'
      target: '${apimGatewayUrl}/${api.name}'
      authType: 'None'
      isSharedToAll: true
      // credentials: {
      //   key: apimSubscription.listSecrets(apimSubscription.apiVersion).primaryKey
      // }
      metadata: {
        type: 'custom_MCP'
      }
    }
  }
]
