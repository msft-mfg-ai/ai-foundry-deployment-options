# Foundry BYO VNet (No Dependencies)

Tests whether AI Foundry works in VNet-injected mode **without** any BYO dependencies (no Storage, AI Search, or Cosmos DB).

## Description

This deployment validates the minimal Foundry + VNet injection scenario:
- New VNet with an agent subnet (delegated to `Microsoft.app/environments`) and a private endpoint subnet
- Log Analytics Workspace and Application Insights
- AI Foundry account with VNet injection (agent subnet wired in) and a GPT model deployment
- One or more AI Projects, each with a user-assigned managed identity
- Project-level capability host (Agents) — created **without** `threadStorageConnections`, `storageConnections`, or `vectorStoreConnections`
- A simple Python hosted agent deployed to the first project from source code
- MCP / OpenAPI tools exposed to the Foundry agent through private endpoints in the VNet

No Cosmos DB, Storage Account, or AI Search resources are created or connected. The Agent Service runs with default (Microsoft-managed) state storage.
The hosted agent uses Foundry source-code deployment, so this sample does not create or require Azure Container Registry.

## Deployment

```bash
# Using Azure CLI for infrastructure only
az deployment group create \
  --resource-group "rg-foundry-byo-vnet" \
  --template-file main.bicep \
  --parameters main.bicepparam

# Using Azure Developer CLI for infrastructure and the hosted agent
azd up
```

After deployment, invoke the hosted agent with:

```bash
azd ai agent invoke "Say hello in one short sentence."
```

The hosted agent includes a `validate_network_injection` tool and a
`network-injection-diagnostics` skill. Run the diagnostics from inside the
hosted runtime with:

```bash
azd ai agent invoke "Validate whether network injection and Azure DNS are working."
```

The tool resolves the agent's own Foundry project hostname through the system
resolver, queries Azure's platform DNS resolver (`168.63.129.16`) directly, and
tests HTTPS/TLS reachability to `FOUNDRY_PROJECT_ENDPOINT`.

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
| `projectsCount` | Number of AI Projects to create under the Foundry account | `1` |
| `apiServices` | Array of external APIs (MCP / OpenAPI) to wire up via private endpoints | `[]` |

## Notes

- The VNet address space defaults to `10.0.0.0/20` in Class-A-supported regions and `192.168.0.0/20` elsewhere — see [`modules/networking/vnet-simple.bicep`](../modules/networking/vnet-simple.bicep).
- Because VNet injection is enabled, the **account-level** capability host is created automatically by the platform; only the **project-level** capability host is created by this template.
- The hosted agent targets the first project and is packaged as a source ZIP. Foundry restores its Python dependencies remotely using the `python_3_13` runtime.
- This option is intended as a baseline test; for scenarios that need persistent thread storage, file storage, or vector store, use [`foundry-basic`](../foundry-basic/) or one of the BYO-resource options.
