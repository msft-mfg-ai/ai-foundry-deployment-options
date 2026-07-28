# ai-gateway-tools

**APIM StandardV2 + Azure API Center — MCP tools registry**

A minimal, self-contained sample that demonstrates using Azure API
Management as a centralised registry / gateway for MCP (Model Context
Protocol) servers, with Azure API Center on top for API discovery and
governance.

Inspired by the `2-apim` stage of
[`Komatsu/ai-landing-zone-01`](../../../../Komatsu/ai-landing-zone-01/),
extracted here as a self-contained, single-region deployment that focuses
purely on the "APIM + API Center + MCP" surface (no AI Foundry account is
provisioned).

## What gets deployed

Single resource group, single region:

| Resource | Purpose |
|---|---|
| Virtual Network | Hosts the APIM v2 injection subnet + a private-endpoint subnet |
| Log Analytics + Application Insights | Diagnostic + APIM logger sinks |
| API Management (**StandardV2**) | Fronts every MCP server as a `type: 'mcp'` API, VNet-integrated (External by default) |
| Azure API Center | Linked to APIM via `apiSources` — auto-imports every API on a schedule |
| Public MCP APIs (5 by default) | MS Learn, Azure REST API specs (gitmcp), GitHub, DeepWiki, Context7 |
| Private MCP APIs (opt-in) | One PE + APIM API per entry in `privateMcps` |

## How it registers MCP servers

The heavy lifting lives in two small modules:

- [`modules/apim/mcp-tools.bicep`](../modules/apim/mcp-tools.bicep) —
  accepts a `publicMcps: publicMcpType[]` list and a
  `privateMcps: privateMcpType[]` list. For each private entry it creates
  a private endpoint (against the target ACA `managedEnvironment` or App
  Service `sites` resource) with the requested private DNS zone linked
  to the sample VNet, then registers the MCP server on APIM.
- [`modules/apim/apim-streamable-mcp/api.bicep`](../modules/apim/apim-streamable-mcp/api.bicep)
  — creates the APIM backend + `type: 'mcp'` API with
  `mcpProperties.transportType = 'streamable'`.
- [`modules/apim/api-center.bicep`](../modules/apim/api-center.bicep) —
  provisions API Center and grants its system-assigned managed identity
  the `API Management Service Reader Role` on the APIM so the APIM
  integration can enumerate APIs.

## Configuring MCP servers

Edit [`main.bicepparam`](./main.bicepparam) to add / remove MCP servers.

### Public MCPs

```bicep
param publicMcps = [
  {
    name: 'ms-learn'
    displayName: 'Microsoft Learn Docs MCP'
    uri: 'https://learn.microsoft.com/api/mcp'
  }
]
```

You can also override the whole list at deploy time via the
`PUBLIC_MCPS_JSON` env var.

### Private MCPs (private endpoint + APIM)

```bicep
param privateMcps = [
  {
    name: 'weather-mcp'
    displayName: 'Weather MCP (ACA private)'
    dnsZoneName: 'privatelink.westus.azurecontainerapps.io'
    type: 'managedEnvironments'
    resourceId: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/managedEnvironments/<env>'
    uri: 'https://aca-mcp-<suffix>.<env-domain>/mcp/mcp'
  }
]
```

- `type` — private-endpoint group ID: `managedEnvironments` for Azure
  Container Apps environments, `sites` for App Service.
- `dnsZoneName` — the matching private DNS zone (e.g.
  `privatelink.<region>.azurecontainerapps.io`,
  `privatelink.azurewebsites.net`).
- `uri` — the upstream URL the MCP server serves on, reached through
  the PE.

Multiple entries can share the same `resourceId` (e.g. several MCP servers
running in the same ACA environment) — the module deduplicates DNS zones
but creates one PE per entry so each server gets its own address in the
peSubnet.

## Deploying

```bash
cd options-infra/ai-gateway-tools
AZD_DISABLE_AGENT_DETECT=1 azd up
```

## Outputs

- `APIM_GATEWAY_URL` — base URL of the APIM instance
- `API_CENTER_NAME` — provisioned API Center
- `REGISTERED_MCP_COUNT` — total (public + private) MCP tools registered
- `PUBLIC_MCP_URLS` / `PRIVATE_MCP_URLS` — per-MCP gateway URLs

Each MCP server is reachable at `${APIM_GATEWAY_URL}/{name}` where `{name}`
is the slug supplied in the parameter list.
