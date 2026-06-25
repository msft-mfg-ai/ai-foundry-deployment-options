# Option: AI Gateway (APIM v2 Premium VNet Injection - Internal) with Foundry

This deployment creates a Foundry environment with an **Azure API Management Premiumv2** instance deployed in **Internal VNet injection** mode with a custom domain. It lets **Foundry Agent Service** use models from APIM, which proxies requests to **one or more** existing Foundry / Azure OpenAI instances with **per-model smart routing** through [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep).


> **Unified architecture note:** This sample uses the shared APIM stack in open mode: `policy-per-model.xml` is applied to the passthrough `inference` API, spec-backed `inference-api-azure` API, and (on Premium/StandardV2-capable SKUs) `openai-api-v1`. The `caller-identity` fragment emits observability headers without contract enforcement, while `per-model-routing` sends traffic to the PAYG-only pool because no contracts set `priority == 1`.

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
│  │  │ - /inference + inference-api-azure APIs                                      │  │         │
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
- Passthrough `inference` API and spec-backed `inference-api-azure` API
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

- [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) creates one APIM backend per `(instance, model, location)`, so a throttled model only disables that backend while sibling models on the same Foundry continue serving traffic.
- The backend module supports two pools per model: `{model-clean}-pool` for priority-1 mixed PTU+PAYG and `{model-clean}-payg-pool` for PAYG-only. These non-quota samples run in open mode, so traffic uses the PAYG-only pool.
- The shared [`per-model-routing`](../modules/apim/per-model-routing-fragment.xml) policy fragment is wired into the passthrough and spec-backed APIs. It reads the model from `/deployments/{name}/...` or the request body's `model`, computes `model-clean`, and routes to the matching pool.
- APIM's system-assigned managed identity is granted **Cognitive Services User** on every backing instance, including instances in other resource groups or subscriptions.

The gateway does not enforce quotas or access contracts in open mode; those controls are enabled by wiring contracts in the `ai-gateway-quota` sample. The spec-backed `inference-api-azure` API at `/azure/openai` renders the APIM test console and model-discovery endpoints from [`FOUNDRY_INSTANCES_JSON`](../modules/apim/advanced/types.bicep).

## Advanced features

The shared `per-model-gateway` orchestrator supports three opt-in features that work in any sample:

### Anthropic (Claude) models on Foundry

Foundry exposes Claude under `/anthropic/*` instead of `/openai/*`. When a deployment in `FOUNDRY_INSTANCES_JSON` carries `"modelFormat": "Anthropic"`, [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) automatically points that backend at `{endpoint}anthropic` while OpenAI/Cohere/DeepSeek/OpenAI-OSS deployments continue to use `{endpoint}openai`. The same gateway transparently serves both `/deployments/{name}/chat/completions` (OpenAI shape) and `/v1/messages` (Anthropic shape); no separate API is needed.

The discovery script picks up Anthropic deployments natively — no config change required.

### Chaining (APIM-to-APIM)

To front another APIM gateway (one that already follows this per-model-gateway convention) instead of a Cognitive Services account, set `EXISTING_APIM_RESOURCE_IDS` alongside `EXISTING_FOUNDRY_RESOURCE_IDS`. The discovery hook enumerates the downstream APIM's catalog and writes an entry with `"isApim": true` into `FOUNDRY_INSTANCES_JSON`. The orchestrator then:

- Points backends at `{endpoint}inference/openai` (the downstream's passthrough catch-all) regardless of model format — model-format split is the downstream's concern.
- Skips the per-instance Cognitive Services RBAC role assignment (the downstream authenticates inbound via JWT, not RBAC).
- Skips per-instance private endpoint creation in network-injected variants (the downstream APIM exposes its own endpoint).

Useful for regional fan-out: one local APIM aggregates several remote APIMs, each fronting their own Foundry accounts.

### Optional inbound JWT validation (`acceptedTenantIds`)

By default the gateway is open — callers reach it anonymously and APIM's managed identity authenticates outbound to Foundry. Set `acceptedTenantIds` to a non-empty list of tenant IDs to require `Authorization: Bearer <token>` on every inbound call with `aud=https://cognitiveservices.azure.com` and an `iss` matching one of the configured tenants (both v1 `sts.windows.net/{tid}/` and v2 `login.microsoftonline.com/{tid}/v2.0` issuers are accepted). Defaults to `[]` for backward compatibility.

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
