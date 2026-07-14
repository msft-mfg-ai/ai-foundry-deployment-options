# Option: AI Gateway private endpoint testing infrastructure

Ephemeral CI infrastructure for the `msft-mfg-ai/foundry-byom-feature-support` BYOM feature-support matrix.

This variant deploys the same private-networked Foundry + APIM Standard v2 private-endpoint topology as [`ai-gateway-pe-custom`](../ai-gateway-pe-custom/), but removes the landing-zone MCP/OpenAPI API hardcodes. Resource naming uses `uniqueString(resourceGroup().id, location)` — so names change between resource groups, but are **stable for a given RG + location**: if you know the RG name and region, you know exactly what resources you'll get.

## What deploys

- Private-networked AI Foundry account and one Foundry project by default.
- APIM Standard v2 with VNet injection and a private endpoint.
- Private endpoints from APIM to the OpenAI/Foundry instances listed in `FOUNDRY_INSTANCES_JSON`.
- Per-model APIM routing for the discovered deployments.
- Two Foundry project APIM connections:
  - static model metadata (`metadata.models`) for `AI_GATEWAY_CONNECTION_STATIC`
  - dynamic model discovery (`modelDiscovery`) for `AI_GATEWAY_CONNECTION_DYNAMIC`

No MCP/OpenAPI landing-zone APIs are deployed unless `apiServices` is explicitly supplied.

## Provisioned tool prerequisites

Beyond the private-networked Foundry + APIM gateway:

- **Bing Grounding** — `Microsoft.Bing/accounts` + `binggrounding` connection on the project (feeds `BING_CONNECTION_ID`, needed by `tool-web-search`). Gated by `enableBingGrounding` (default `true`); set env var `ENABLE_BING_GROUNDING=false` if your subscription has Bing resources suspended.
- **AI Search** — provisioned by `ai-dependencies-with-dns.bicep` and auto-connected to the project (`AZURE_AI_SEARCH_CONNECTION_ID`). A `byom-test` index with 3 seed documents is created by the `postprovision` hook (`scripts/create_index.py`) — the hook briefly opens the search firewall, runs the seed, then closes it.

SharePoint, Fabric, and Logic App connections are **not** deployable here — they need pre-existing external resources; set `SHAREPOINT_CONNECTION_ID`, `FABRIC_CONNECTION_ID`, `LOGIC_APP_RESOURCE_ID` in the BYOM `byom` GitHub Environment directly. MCP endpoints likewise stay as plain URLs (`MCP_SERVER_URL*`) — the `tool-mcp/*` tests hit them directly.

## Required environment

- `AZURE_ENV_NAME` - azd environment name; drives the resource group name.
- `AZURE_LOCATION` - deployment region.
- `FOUNDRY_INSTANCES_JSON` - populated by the `preprovision-list-foundry-models` hook from existing OpenAI/Foundry model deployments.

The backing instance list must include at least one non-APIM OpenAI/Foundry instance. For the BYOM matrix, include a deployment named `gpt-4o-mini` at minimum. Optional useful deployments include `gpt-4o`, `dall-e-2`, `gpt-image-1`, and `o3-mini`; do not add sora, realtime, or embeddings just for this matrix.

## Connection names

`resourceToken` is `toLower(uniqueString(resourceGroup().id, location))` — stable for a given RG + location. With `projectsCount = 1`, project names are:

```text
ai-project-${resourceToken}-1
```

`connections-apim-gateway.bicep` then creates these OpenAI project connections:

```text
AI_GATEWAY_CONNECTION_STATIC  = apim-${resourceToken}-openai-s-for-ai-project-${resourceToken}-1
AI_GATEWAY_CONNECTION_DYNAMIC = apim-${resourceToken}-openai-d-for-ai-project-${resourceToken}-1
```

The exact strings are emitted as Bicep outputs (see below), so downstream callers should read them via `azd env get-value AI_GATEWAY_CONNECTION_STATIC` rather than hardcoding.

## CI-consumed outputs

| Output | Description |
|--------|-------------|
| `PROJECT_ENDPOINT` | `https://<foundry>.services.ai.azure.com/api/projects/<project>` |
| `AI_GATEWAY_CONNECTION_STATIC` | Static APIM connection name for BYOM tests |
| `AI_GATEWAY_CONNECTION_DYNAMIC` | Dynamic APIM connection name for BYOM tests |
| `BING_CONNECTION_ID` | ARM ID of the `binggrounding` project connection |
| `AZURE_AI_SEARCH_CONNECTION_ID` | ARM ID of the AI Search project connection |
| `AZURE_AI_SEARCH_INDEX_NAME` | Name of the seeded index (`byom-test`) |
| `AI_SEARCH_SERVICE_NAME` | Consumed by the postprovision hook (firewall open/close) |
| `AI_SEARCH_ENDPOINT` | Consumed by the postprovision hook (index seed) |
| `RESOURCE_GROUP` | Resource group name, for teardown |
| `FOUNDRY_NAME` | Foundry account name, for purge |
| `project_connection_strings` | Existing project endpoint list |
| `project_names` | Existing project name list |
| `config_validation_result` | Fails deployment when `FOUNDRY_INSTANCES_JSON` is empty |

## Deployment

```bash
cd options-infra/ai-gateway-pe-testing
azd up
```
