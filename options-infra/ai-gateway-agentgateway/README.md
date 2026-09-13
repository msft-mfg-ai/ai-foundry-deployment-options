# Option: agentgateway with Azure AI Foundry

This option deploys [agentgateway](https://github.com/agentgateway/agentgateway) as a unified LLM, MCP, and A2A gateway for Azure AI Foundry.

> This is an agentgateway-based sample, not the APIM `policy-per-model.xml` stack. Use the APIM options for the repository's canonical APIM routing architecture.

## Architecture

- Azure AI Foundry account and project with Agent Service capability hosts.
- Standalone agentgateway `v1.5.0` on Azure Container Apps.
- One or more selected Foundry / AI Services resources reached through private endpoints.
- User-assigned managed identity for agentgateway-to-Foundry authentication.
- Foundry Model Gateway connections using the project managed identity.
- Entra OIDC for the browser UI, JWT validation for LLM/A2A, and native Entra MCP authorization.
- PostgreSQL for analytics, logs, and hybrid UI configuration storage.
- Private FastMCP and A2A sample services deployed through `azd`.
- Key Vault, Log Analytics, Application Insights, VNet, private DNS, and ACR.

The public surface is the Container Apps HTTPS hostname. The agentgateway admin interface remains loopback-only.

## Prerequisites

- Azure CLI and Azure Developer CLI authenticated to the target tenant/subscription.
- Permission to create Azure resources, role assignments, app registrations, service principals, and app credentials.
- One or more existing Foundry / AI Services resources with deployed models.

Select the backing Foundry resources with the same input used by the other AI Gateway options:

```bash
azd env set EXISTING_FOUNDRY_RESOURCE_IDS \
  "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-1>,/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-2>"
```

If this value is not set, the POSIX preprovision hook opens the repository's standard interactive Foundry selector. The discovery hook queries every selected resource and writes `FOUNDRY_INSTANCES_JSON`, including deployed model names, versions, and formats. The generated agentgateway configuration publishes each discovered model name and load-balances it across selected resources that host that model.

The same preprovision phase creates the gateway API and UI Entra applications. The postprovision hook registers the final ACA callback and resource URLs.

## Deploy

```bash
cd options-infra/ai-gateway-agentgateway
AZD_DISABLE_AGENT_DETECT=1 azd up
```

If Azure AI Search Basic has no capacity in the gateway region, set a dedicated
Search region before deploying:

```bash
azd env set AI_SEARCH_LOCATION centralus
AZD_DISABLE_AGENT_DETECT=1 azd up
```

Important outputs:

| Output | Description |
|---|---|
| `AGENTGATEWAY_URL` | Unified gateway base URL |
| `AGENTGATEWAY_UI_URL` | Entra-protected UI |
| `AGENTGATEWAY_MCP_URL` | MCP endpoint |
| `AGENTGATEWAY_A2A_URL` | A2A endpoint |
| `FOUNDRY_PROJECT_NAME` | Created Foundry project |

## Authentication

The gateway resource app exposes `gateway_access` and `mcp_access` delegated scopes plus an application role for workload callers.

- Foundry requests a token for `AGENTGATEWAY_API_AUDIENCE` with its project managed identity.
- Browser users authenticate through the confidential UI client.
- MCP clients discover Entra authorization metadata through agentgateway.
- agentgateway calls every selected Foundry resource with its user-assigned identity and the `Cognitive Services OpenAI User` role.

## Local gateway

The local Compose configuration uses API keys because the official container does not include Azure CLI credentials.

```bash
cd gateway
cp .env.example .env
mkdir -p data
docker compose up -d
```

Open `http://localhost:4000/ui/`. The local configuration intentionally omits the deployed Entra policies.

## Validation

```bash
az bicep build --file main.bicep
az bicep lint --file main.bicep
```

After deployment, verify UI login, `401` responses for unauthenticated protocol calls, Foundry model inference, MCP tool invocation, A2A routing, and persistence across an ACA revision restart.

## Upgrade

The image is pinned intentionally. Update `agentgatewayImage` only after validating the new release's configuration schema and authentication behavior.
