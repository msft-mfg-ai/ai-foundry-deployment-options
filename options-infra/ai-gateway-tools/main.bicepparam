using 'main.bicep'

// Optional: override the default public MCP list via env var (JSON).
// Example:
//   PUBLIC_MCPS_JSON='[{"name":"ms-learn","uri":"https://learn.microsoft.com/api/mcp","displayName":"MS Learn"}]'
// Set PUBLIC_MCPS_JSON to a JSON array to override the default list; leave
// unset (or set to "null") to keep the defaults from main.bicep.
var publicMcpsJson = readEnvironmentVariable('PUBLIC_MCPS_JSON', 'null')
param publicMcps = json(publicMcpsJson)

// Private MCPs (behind a private endpoint). Extend / edit this list to
// register your own ACA-hosted or App-Service-hosted MCP servers.
//
// The default set below points at existing ACA-hosted MCP servers in
// `foundry-landing-zone-westus` — reuse them, or replace with your own
// resources. Each entry:
//   name         → slug used as the APIM path (`/{name}`)
//   uri          → upstream URL reached through the PE
//   resourceId   → target resource ID (ACA managedEnvironment or App Service site)
//   type         → PE group ID: `managedEnvironments` (ACA) or `sites` (App Service)
//   dnsZoneName  → private DNS zone for the target
//   displayName  → optional human-readable label
param privateMcps = [
  {
    name: 'weather-mcp'
    displayName: 'Weather MCP (ACA private)'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://aca-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp/mcp'
  }
  {
    name: 'sample-mcp'
    displayName: 'Sample MCP (ACA private)'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://sample-mcp-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp'
  }
  {
    name: 'server-mcp'
    displayName: 'Server MCP (ACA private)'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/foundry-landing-zone-westus/providers/Microsoft.App/managedEnvironments/acaqczp34j2qg7pk'
    uri: 'https://mcp-server-qczp34j2qg7pk.ashyocean-7ea49412.westus.azurecontainerapps.io/mcp'
  }
]

var apimPublicEnabledValue = readEnvironmentVariable('APIM_PUBLIC_ENABLED', '')
param apimPublicEnabled = toLower(apimPublicEnabledValue) == 'false' ? false : true
