# Option: Two Foundries integrated with one private AI Gateway

This sample deploys two private Azure AI Foundry accounts, one project in each
account, and one shared API Management AI Gateway. It is based on
[`ai-gateway-pe-testing`](../ai-gateway-pe-testing/) and the upstream
[`project-ai-gateway`](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/01-connections/project-ai-gateway)
sample.

## Architecture

```text
                          One VNet
  +-------------------------------------------------------+
  | agent-subnet                 agent-subnet-1           |
  |      |                              |                 |
  | Foundry 1                       Foundry 2              |
  |   Project 1                       Project 2            |
  |      \                              /                  |
  |       +---- APIM Standard v2 AI Gateway ----+         |
  |                    |                                  |
  |             private endpoints                         |
  +--------------------|----------------------------------+
                       v
          Existing Foundry / AI Services model backends
```

Each Foundry has its own subnet delegated exclusively to
`Microsoft.App/environments`. Both projects share the same private Storage,
Cosmos DB, AI Search, monitoring resources, and APIM gateway.

## Gateway integration

For each Foundry/project pair the deployment creates:

1. An account-to-APIM ARM resource link.
2. An account-named APIM API that reuses the shared routing policy, backend pools, and quota keys.
3. A published APIM product whose ID contains the complete Foundry account and project names, associated with that account-specific API.
4. An active APIM subscription scoped to that product.
5. A project-to-product ARM resource link, which marks the project as gateway enabled.
6. Static and dynamic `ApiManagement` project connections using project managed identity.

Foundry uses the account-specific API ID to correlate each project product with
its parent Foundry account. Bidirectional ARM resource links connect the Foundry
account and APIM service. Foundry only runs its account-registration handler
when those links are written directly through the Links REST endpoint, so the
`azd` postprovision hook performs those two idempotent writes using the deploying
user's existing ARM permissions. Project links use short opaque IDs to avoid
ARM's 64-character link-name limit. An account-named backend marker is also
registered for discovery, but the account APIs remain operationally shared:
they use the same policy XML, per-model backend pools, and APIM quota counter
keys as the canonical `inference-api`.

## Deployed resources

- One VNet with two delegated agent subnets, an APIM v2 subnet, and a private-endpoint subnet.
- Two private Foundry accounts with one capability-host project each.
- Shared private Storage, Cosmos DB, AI Search, Log Analytics, and Application Insights.
- APIM Standard v2 with VNet injection, a private endpoint, and per-model routing.
- Private endpoints to both new Foundries and every configured model backend.
- Per-project APIM products, subscriptions, resource links, and Foundry connections.

## Prerequisites

The AI Gateway needs at least one existing Foundry or Azure AI Services account
with a model deployment. Set one of the supported discovery inputs:

```bash
export EXISTING_FOUNDRY_RESOURCE_IDS="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<backend-1>,/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<backend-2>"
```

The `azd` preprovision hook discovers deployments and writes
`FOUNDRY_INSTANCES_JSON`, which is consumed by `main.bicepparam`.

## Deploy

```bash
cd options-infra/ai-gateway-integrated
AZD_DISABLE_AGENT_DETECT=1 azd up
```

Set `APIM_PUBLIC_ENABLED=true` to retain APIM public access. The default is a
private-only gateway after its private endpoint is provisioned.

The postprovision hook is required because native ARM deployment of equivalent
account/APIM resource links does not invoke Foundry's gateway-registration
handler. If deploying `main.bicep` directly instead of using `azd`, export the
deployment outputs and run:

```bash
sh ../scripts/postprovision-register-foundry-gateway.sh
```

## Outputs

| Output | Description |
| --- | --- |
| `FOUNDRY_NAMES` | Names of both Foundry accounts |
| `PROJECT_NAMES` | Names of both projects |
| `PROJECT_ENDPOINTS` | Foundry project endpoints |
| `AI_GATEWAY_CONNECTION_STATIC` | Static gateway connection name per project |
| `AI_GATEWAY_CONNECTION_DYNAMIC` | Dynamic gateway connection name per project |
| `AI_GATEWAY_PRODUCT_NAMES` | APIM product name per project |
| `APIM_BASE_URL` | Shared gateway URL |
| `APIM_RESOURCE_ID` | APIM resource ID |
| `AGENT_SUBNET_RESOURCE_IDS` | The two delegated subnet resource IDs |
