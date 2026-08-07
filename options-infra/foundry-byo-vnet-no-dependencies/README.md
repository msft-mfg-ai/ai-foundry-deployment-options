# Foundry BYO VNet (No Dependencies)

Tests whether AI Foundry works in VNet-injected mode **without** any BYO dependencies (no Storage, AI Search, or Cosmos DB).

## Description

This deployment validates the minimal Foundry + VNet injection scenario:
- New VNet with an agent subnet (delegated to `Microsoft.app/environments`) and a private endpoint subnet
- Log Analytics Workspace and Application Insights
- AI Foundry account with VNet injection (agent subnet wired in) and a GPT model deployment
- One or more AI Projects, each with a user-assigned managed identity
- Project-level capability host (Agents) — created **without** `threadStorageConnections`, `storageConnections`, or `vectorStoreConnections`
- Prompt agents and Python hosted agents connected to the weather and sample MCP servers
- The MCP and OpenAPI services exposed through private endpoints in the VNet

No Cosmos DB, Storage Account, or AI Search resources are created or connected. The Agent Service runs with default (Microsoft-managed) state storage.
The hosted agent uses Foundry source-code deployment, so this sample does not create or require Azure Container Registry.

## Deployment

```bash
# Using Azure CLI for infrastructure only
az deployment group create \
  --resource-group "rg-foundry-byo-vnet" \
  --template-file main.bicep \
  --parameters main.bicepparam

# Provision infrastructure and export both project outputs
AZD_DISABLE_AGENT_DETECT=1 azd provision

# Deploy one hosted agent and one MCP prompt agent to each project
./scripts/deploy-agents.sh

# PowerShell
.\scripts\deploy-agents.ps1
```

The `azure.ai.agents` beta extension resolves hosted-agent deployments from the
single global `AZURE_AI_PROJECT_ID` value. The deployment script therefore
switches that value before deploying each service. It restores the original
project context when one exists, or leaves a fresh environment targeting the
no-capability-host project.

After deployment, invoke a hosted agent with:

```bash
azd ai agent invoke hosted-agent-no-cap "Say hello in one short sentence."
azd ai agent invoke hosted-agent-with-cap "Say hello in one short sentence."
```

The hosted agent includes a `validate_network_injection` tool and a
`network-injection-diagnostics` skill. Run the diagnostics from inside the
hosted runtime with:

```bash
azd ai agent invoke hosted-agent-no-cap "Validate whether network injection and Azure DNS are working."
azd ai agent invoke hosted-agent-with-cap "Validate whether network injection and Azure DNS are working."
```

Each hosted agent receives its `MCP_SERVER_URL` and `MCP_SERVER_NAME` from the
Bicep outputs and connects directly to the private sample MCP endpoint. The
script deploys `hosted-agent-no-cap` and `hosted-agent-with-cap`, then discovers
all shared Foundry MCP connections and creates `prompt-mcp-no-cap` and
`prompt-mcp-with-cap`, each with all discovered MCP servers.

## Observed behavior

The two-project test confirms that hosted agents run in both projects. Their
in-container diagnostics resolve the Foundry and sample MCP endpoints to private
addresses and successfully call MCP `tools/list`.

Prompt agents can be created in both projects, but prompt-agent execution
requires the project capability host. `prompt-mcp-with-cap` can invoke the
sample MCP `add` tool, while `prompt-mcp-no-cap` returns a `tool_server_error`
even for a basic response request.

Run all four live checks against the selected azd environment:

```bash
cd tests
uv sync
AZD_ENV_NAME=two-project-agents-test uv run pytest
```

The suite intentionally fails the `prompt-mcp-no-cap` case with an explicit
message that prompt execution requires a project-level capability host. The
expected summary for this comparison deployment is `3 passed, 1 failed`.

Hosted agents use `MCPStreamableHTTPTool`, so MCP traffic originates from the
hosted agent container and follows the VNet-injected private network path.

The tool resolves the agent's own Foundry project hostname through the system
resolver, queries Azure's platform DNS resolver (`168.63.129.16`) directly, and
tests HTTPS/TLS reachability to `FOUNDRY_PROJECT_ENDPOINT`. When
`MCP_SERVER_URL` is configured, it also resolves the MCP hostname, reports its
private IP addresses, and performs an MCP `tools/list` request. It also uses
`AZURE_AI_PROJECT_ID` to query account-level and project-level capability hosts
through Azure Resource Manager.

Each hosted agent has a distinct per-agent instance identity. The deployment
script grants that identity Reader on the Foundry resource group so the
diagnostic can read capability hosts. The deploying user therefore needs
permission to create role assignments at resource-group scope.

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
| `projectsCount` | Number of AI Projects to create under the Foundry account | `1` |
| `apiServices` | Array of external APIs (MCP / OpenAPI) to wire up via private endpoints | `[]` |

## Notes

- The VNet address space defaults to `10.0.0.0/20` in Class-A-supported regions and `192.168.0.0/20` elsewhere — see [`modules/networking/vnet-simple.bicep`](../modules/networking/vnet-simple.bicep).
- Because VNet injection is enabled, the **account-level** capability host is created automatically by the platform; only the **project-level** capability host is created by this template.
- Do not use `azd up` for the agent deployment in this option. Run `azd provision` and then the deployment script so each hosted service is sent to the correct project.
- The hosted agents reuse the same source package. Foundry restores their Python dependencies remotely using the `python_3_13` runtime.
- This option is intended as a baseline test; for scenarios that need persistent thread storage, file storage, or vector store, use [`foundry-basic`](../foundry-basic/) or one of the BYO-resource options.
