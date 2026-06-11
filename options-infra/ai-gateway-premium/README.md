# Option: AI Gateway (APIM v2 Premium VNet Injection - Internal) with Foundry

This deployment creates a Foundry environment with an **Azure API Management Premiumv2** instance deployed in **Internal VNet injection** mode with a custom domain. It lets **Foundry Agent Service** use models from APIM, which proxies requests to **one or more** existing Foundry / Azure OpenAI instances with **per-model smart routing** through [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep).

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry VNet                             │                     │
│  │  Project(s), private dependencies, upstream private endpoints    │                     │
│  └───────────────────────────────────────────────┬──────────────────┘                     │
│                                                  │ VNet peering + linked DNS              │
│                                                  ▼                                        │
│  ┌───────────────────────────────────────────────────────────────────────────────┐         │
│  │ Dedicated APIM VNet                                                           │         │
│  │  ┌─────────────────────────────────────────────────────────────────────────┐  │         │
│  │  │ Azure API Management Premiumv2 (Internal)                              │  │         │
│  │  │ - Custom domain: apim.{customDomain}                                   │  │         │
│  │  │ - /inference/openai + /azure APIs                                      │  │         │
│  │  │ - Per-model PAYG pools                                                  │  │         │
│  │  └───────────────────────────────────────┬─────────────────────────────────┘  │         │
│  └──────────────────────────────────────────┼────────────────────────────────────┘         │
│                                             │ Private endpoints (one per instance)          │
└─────────────────────────────────────────────┼───────────────────────────────────────────────┘
                                              ▼
                             ┌──────────────────────────────────────────────┐
                             │  1..N Foundry / Azure OpenAI instances       │
                             │  Per-instance, per-model APIM backends       │
                             └──────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls APIM through the internal custom domain `apim.{customDomain}`
2. APIM extracts the requested model and routes to that model's PAYG pool
3. APIM reaches each backing instance through a private endpoint in the Foundry VNet

## Deployed Resources

### Networking
- **Main Virtual Network** (`192.168.0.0/21`) with subnets for private endpoints and agent services
- **Dedicated APIM Virtual Network** (`192.168.100.0/23`) for Premiumv2 internal injection
- **VNet Peering** between the Foundry VNet and APIM VNet
- **Private DNS Zones** for APIM (`privatelink.azure-api.net`), the custom-domain zone, Azure OpenAI (`privatelink.openai.azure.com`), Key Vault, Storage, Cosmos DB, and AI Search
- DNS zones are linked to both VNets; one private endpoint is created per backing Foundry / Azure OpenAI instance

### Foundry
- **Foundry account** with managed identity
- **Foundry project(s)** with Capability Hosts (configurable count)
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints

### AI Gateway (APIM v2 Premium)
- **Azure API Management Premiumv2** in internal VNet-injected mode
- Custom domain `apim.{customDomain}` backed by a Key Vault PFX certificate accessed through UAMI
- Lightweight `apim-hostname-update.bicep` deployment applies hostname bindings after APIM creation
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
- `APIM_LOCATION` - Location for the APIM Premiumv2 instance (defaults to deployment location)
- `PROJECTS_COUNT` - Number of Foundry projects to create (default: 3)

## Per-model smart routing

All gateway variants use [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep) for APIM orchestration:

- [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) creates one APIM backend per `(instance, model)`, so a throttled deployment only disables that backend while sibling deployments continue serving traffic.
- One PAYG backend pool is created per model, named `{model-clean}-payg-pool` after removing `.` and `-` from the model name; all instances serving that model join the same pool for APIM load balancing.
- The shared [`per-model-routing`](../modules/apim/per-model-routing-fragment.xml) policy fragment is wired into both `/inference/openai` and `/azure`. It reads the model from `/deployments/{name}/...` or the request body's `model`, computes `model-clean`, and routes to the matching pool.
- APIM's system-assigned managed identity is granted **Cognitive Services User** on every backing instance, including instances in other resource groups or subscriptions.

The gateway does not enforce quotas, JWT validation, or access contracts; those controls live in the `ai-gateway-quota` sample. The spec-backed `/azure` API renders the APIM test console and model-discovery endpoints from [`FOUNDRY_INSTANCES_JSON`](../modules/apim/advanced/types.bicep).

## Deployment

```bash
cd options-infra/ai-gateway-premium
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

- **Enterprise/Regulated environments**: Internal Premiumv2 APIM with custom domain
- **Centralized AI Gateway**: Single point of control for AI model access
- **Landing Zone integration**: Connect privately to shared Foundry / Azure OpenAI instances
- **Private tool integration**: Publish MCP/OpenAPI services alongside model APIs

## Variants

| Sample | Difference |
|--------|------------|
| [ai-gateway-basic](../ai-gateway-basic/) | Public APIM Basicv2, no VNet at all |
| [ai-gateway](../ai-gateway/) | Public APIM Basicv2 with private Foundry dependencies |
| [ai-gateway-internal](../ai-gateway-internal/) | Developer SKU with internal VNet injection and per-instance upstream private endpoints |
| [ai-gateway-pe](../ai-gateway-pe/) | Standardv2 with external VNet injection plus APIM private endpoint |
| [ai-gateway-pe-custom](../ai-gateway-pe-custom/) | Standardv2 + PE, but provisions its own OpenAI account and test deployments |
