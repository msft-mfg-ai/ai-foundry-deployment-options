# Option: AI Gateway (Internal APIM) with Foundry

This deployment creates a Foundry environment with a **Developer SKU Azure API Management (APIM)** instance in **Internal VNet injection** mode acting as an AI Gateway. It lets **Foundry Agent Service** use models from APIM, which proxies requests to **one or more** existing Foundry / Azure OpenAI instances with **per-model smart routing** through [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep).

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry                                  │                     │
│  │  Project(s) with Capability Hosts and private dependencies       │                     │
│  │  Agent Service ─── VNet injection ───────────────────────────────┼──┐                  │
│  └──────────────────────────────────────────────────────────────────┘  │                  │
│                                                                        ▼                  │
│                        ┌─────────────────────────────────────────────────────┐            │
│                        │ Azure API Management Developer (Internal VNet)      │            │
│                        │ - No public endpoint                                │            │
│                        │ - /inference/openai + /azure APIs                  │            │
│                        │ - Per-model PAYG pools                              │            │
│                        └──────────────────────────┬──────────────────────────┘            │
│                                                   │                                       │
│  VNet │ Private DNS │ Key Vault │ Storage │ Cosmos │ AI Search │ MCP/OpenAPI services      │
└───────────────────────────────────────────────────┼───────────────────────────────────────┘
                                                    │ Private endpoints (one per instance)
                                                    ▼
                             ┌──────────────────────────────────────────────┐
                             │  1..N Foundry / Azure OpenAI instances       │
                             │  Per-instance, per-model APIM backends       │
                             └──────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls the internal APIM AI Gateway
2. APIM extracts the requested model and routes to that model's PAYG pool
3. APIM reaches each backing instance through a private endpoint in the local VNet

## Deployed Resources

### Networking
- **Virtual Network** with subnets for private endpoints, APIM internal injection, and agent services
- **Private DNS Zones** for Azure OpenAI (`privatelink.openai.azure.com`), Key Vault, Storage, Cosmos DB, and AI Search
- **One private endpoint per backing Foundry / Azure OpenAI instance** so internal APIM can reach upstream models

### Foundry
- **Foundry account** with managed identity
- **Foundry project(s)** with Capability Hosts (configurable count)
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints

### AI Gateway (APIM)
- **Azure API Management Developer SKU** in internal VNet-injected mode
- Per-model backends + PAYG pools synthesised from `FOUNDRY_INSTANCES_JSON`
- Passthrough `/inference/openai` API and spec-backed `/azure` API
- Managed identity with Cognitive Services User role on every backing instance
- Optional `apiServices` entries for private MCP/OpenAPI services are exposed through APIM and private DNS

### Monitoring
- **Log Analytics Workspace**
- **Application Insights** for APIM and Foundry telemetry

## Prerequisites

Set the backing Foundry / Azure AI Services instances before deployment:

```bash
export EXISTING_FOUNDRY_RESOURCE_IDS="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-1>,/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry-2>"
```

`EXISTING_FOUNDRY_RESOURCE_IDS` is the preferred comma-separated, multi-instance form. For backwards compatibility, the discovery hook also accepts `EXISTING_FOUNDRY_RESOURCE_ID` or legacy `OPENAI_RESOURCE_ID` for a single instance.

The `azure.yaml` `preprovision` hook runs [`preprovision-list-foundry-models.sh`](../scripts/preprovision-list-foundry-models.sh) / `.ps1`, calls ARM (`az cognitiveservices account deployment list`) to enumerate model deployments on every instance, and writes `FOUNDRY_INSTANCES_JSON`. `main.bicepparam` reads that JSON into the `foundryInstances` parameter using the [`foundryInstanceType[]`](../modules/apim/advanced/types.bicep) shape. Deployment fails fast with a clear error when no instances are configured.

### Optional Parameters
- `PROJECTS_COUNT` - Number of Foundry projects to create (default: 1)

## Per-model smart routing

All gateway variants use [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep) for APIM orchestration:

- [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) creates one APIM backend per `(instance, model)`, so a throttled deployment only disables that backend while sibling deployments continue serving traffic.
- One PAYG backend pool is created per model, named `{model-clean}-payg-pool` after removing `.` and `-` from the model name; all instances serving that model join the same pool for APIM load balancing.
- The shared [`per-model-routing`](../modules/apim/per-model-routing-fragment.xml) policy fragment is wired into both `/inference/openai` and `/azure`. It reads the model from `/deployments/{name}/...` or the request body's `model`, computes `model-clean`, and routes to the matching pool.
- APIM's system-assigned managed identity is granted **Cognitive Services User** on every backing instance, including instances in other resource groups or subscriptions.

The gateway does not enforce quotas, JWT validation, or access contracts; those controls live in the `ai-gateway-quota` sample. The spec-backed `/azure` API renders the APIM test console and model-discovery endpoints from [`FOUNDRY_INSTANCES_JSON`](../modules/apim/advanced/types.bicep).

## Deployment

```bash
cd options-infra/ai-gateway-internal
azd up
```

## Outputs

| Output | Description |
|--------|-------------|
| `project_connection_strings` | Connection strings for Foundry projects |
| `project_names` | Names of the deployed Foundry projects |
| `FOUNDRY_NAME` | Name of the Foundry account |
| `config_validation_result` | Validation status of the configuration |

## Use Cases

- **Enterprise/Regulated environments**: APIM has no public endpoint
- **Centralized AI Gateway**: Single point of control for AI model access
- **Landing Zone integration**: Connect privately to shared Foundry / Azure OpenAI instances
- **Private tool integration**: Publish MCP/OpenAPI services alongside model APIs

## Variants

| Sample | Difference |
|--------|------------|
| [ai-gateway-basic](../ai-gateway-basic/) | Public APIM Basicv2, no VNet at all |
| [ai-gateway](../ai-gateway/) | Public APIM Basicv2 with private Foundry dependencies |
| [ai-gateway-pe](../ai-gateway-pe/) | Standardv2 with external VNet injection plus APIM private endpoint |
| [ai-gateway-pe-custom](../ai-gateway-pe-custom/) | Standardv2 + PE, but provisions its own OpenAI account and test deployments |
| [ai-gateway-premium](../ai-gateway-premium/) | Premiumv2 internal VNet, custom domain, dedicated APIM VNet |
