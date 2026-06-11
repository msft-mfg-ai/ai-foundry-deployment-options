# Option: AI Gateway (External APIM) with Foundry Basic

This deployment creates a Foundry Basic environment with an **external Azure API Management (APIM) Basic v2** instance acting as an AI Gateway. The goal is to allow **Foundry Agent Service** to use models from APIM, which proxies requests to **one or more** external Foundry / Azure OpenAI resources with **per-model smart routing**.

Built on the shared [`modules/apim/per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep) orchestrator — every backing model gets its own APIM backend + PAYG pool, and a reusable [`per-model-routing`](../modules/apim/per-model-routing-fragment.xml) policy fragment dispatches each inbound request to the right pool.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry Basic                            │                     │
│  │  Project(s), public traffic, no VNet or private endpoints        │                     │
│  └───────────────────────────────────────────────┬──────────────────┘                     │
│                                                  │                                        │
│                                                  ▼                                        │
│                        ┌─────────────────────────────────────────────────────┐            │
│                        │ Azure API Management Basicv2 (Public)               │            │
│                        │ - Passthrough API: /inference/openai                │            │
│                        │ - Spec-backed API: /azure                           │            │
│                        │ - Per-model routing fragment                        │            │
│                        │ - PAYG pools: {model-clean}-payg-pool             │            │
│                        └──────────────────────────┬──────────────────────────┘            │
│                                                   │                                       │
│  Supporting Services: Key Vault │ Log Analytics │ App Insights                            │
└───────────────────────────────────────────────────┼───────────────────────────────────────┘
                                                    │ Public Internet
                                                    ▼
                             ┌──────────────────────────────────────────────┐
                             │  1..N Foundry / Azure OpenAI instances       │
                             │  Per-instance, per-model APIM backends       │
                             └──────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls the public APIM AI Gateway
2. APIM extracts the requested model and routes to that model's PAYG pool
3. APIM uses managed identity for authentication to the selected Foundry / Azure OpenAI instance

## Deployed Resources

### Foundry
- **Foundry account** with managed identity
- **Foundry project(s)** with Capability Hosts (configurable count)
- No VNet, agent subnet, or private endpoints in this basic sample

### AI Gateway (APIM)
- **Azure API Management Basicv2** in external/public mode
- Per-model backends + PAYG pools synthesised from `FOUNDRY_INSTANCES_JSON`
- Passthrough `/inference/openai` API and spec-backed `/azure` API
- Managed identity with Cognitive Services User role on every backing instance

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
cd options-infra/ai-gateway-basic
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

- **Development/Testing**: Quick setup without private networking complexity
- **Centralized AI Gateway**: Single point of control for AI model access
- **Landing Zone integration**: Connect to shared Foundry / Azure OpenAI instances
- **Per-model routing**: Balance each model across every configured backing instance

## Variants

| Sample | Difference |
|--------|------------|
| [ai-gateway](../ai-gateway/) | Public APIM Basicv2 with private Foundry dependencies |
| [ai-gateway-internal](../ai-gateway-internal/) | Developer SKU with internal VNet injection and per-instance upstream private endpoints |
| [ai-gateway-pe](../ai-gateway-pe/) | Standardv2 with external VNet injection plus APIM private endpoint |
| [ai-gateway-pe-custom](../ai-gateway-pe-custom/) | Standardv2 + PE, but provisions its own OpenAI account and test deployments |
| [ai-gateway-premium](../ai-gateway-premium/) | Premiumv2 internal VNet, custom domain, dedicated APIM VNet |
