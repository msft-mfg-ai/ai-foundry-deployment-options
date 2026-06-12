# Option: AI Gateway (APIM Standard v2 + Private Endpoint) with In-Deployment OpenAI

This deployment creates a Foundry environment with an **Azure API Management (APIM) Standardv2** instance in **External VNet injection** mode plus an APIM private endpoint. It uses [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep) for **per-model smart routing**; instead of external fan-out, this sample provisions one local Azure OpenAI account and synthesizes the same gateway instance shape from it.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry                                  │                     │
│  │  Project(s) with Capability Hosts and private dependencies       │                     │
│  └───────────────────────────────────────────────┬──────────────────┘                     │
│                                                  │ APIM private endpoint                  │
│                                                  ▼                                        │
│                        ┌─────────────────────────────────────────────────────┐            │
│                        │ Azure API Management Standardv2 (External + PE)     │            │
│                        │ - /inference/openai + /azure APIs                  │            │
│                        │ - Per-model routing fragment                        │            │
│                        │ - PAYG pools for test-gpt-4.1 and test-gpt-5.2      │            │
│                        └──────────────────────────┬──────────────────────────┘            │
│                                                   │                                       │
│  VNet │ Private DNS │ Key Vault │ Storage │ Cosmos │ AI Search │ MCP/OpenAPI services      │
└───────────────────────────────────────────────────┼───────────────────────────────────────┘
                                                    │ Single private endpoint
                                                    ▼
                             ┌──────────────────────────────────────────────┐
                             │  In-deployment Azure OpenAI account          │
                             │  Deployments: test-gpt-4.1, test-gpt-5.2    │
                             └──────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls APIM through the APIM private endpoint
2. APIM extracts the requested model and routes to that model's PAYG pool
3. APIM reaches the locally provisioned Azure OpenAI account through a private endpoint

## Deployed Resources

### Networking
- **Virtual Network** with subnets for private endpoints, APIM external injection, and agent services
- **Private DNS Zones** for APIM (`privatelink.azure-api.net`), Azure OpenAI (`privatelink.openai.azure.com`), Key Vault, Storage, Cosmos DB, and AI Search
- **APIM private endpoint**; `APIM_PUBLIC_ENABLED` controls whether public access remains enabled after PE attachment
- **Single private endpoint** to the in-deployment Azure OpenAI account

### Foundry
- **Foundry account** with managed identity
- **Foundry project(s)** with Capability Hosts (configurable count)
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints
- **Azure OpenAI account** created in-deployment with `test-gpt-4.1` and `test-gpt-5.2` deployments

### AI Gateway (APIM)
- **Azure API Management Standardv2** in external VNet-injected mode with private endpoint
- Per-model backends + PAYG pools synthesised from the in-deployment OpenAI account
- Passthrough `/inference/openai` API and spec-backed `/azure` API
- Managed identity with Cognitive Services User role on the local OpenAI account
- Optional `apiServices` entries for private MCP/OpenAPI services are exposed through APIM and private DNS

### Monitoring
- **Log Analytics Workspace**
- **Application Insights** for APIM and Foundry telemetry

## Prerequisites

No external Foundry / Azure OpenAI resource is required. This sample provisions its own Azure OpenAI account in-deployment with `test-gpt-4.1` and `test-gpt-5.2`, then routes to it through per-model PAYG pools. The deployment synthesizes a single-instance `foundryInstances[]` value from that local account.

### Optional Parameters
- `PROJECTS_COUNT` - Number of Foundry projects to create (default: 1)
- `APIM_PUBLIC_ENABLED` - Set to `true` to keep APIM public access enabled after the private endpoint is attached (default: `false`)

## Per-model smart routing

All gateway variants use [`per-model-gateway.bicep`](../modules/apim/per-model-gateway.bicep) for APIM orchestration:

- [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) creates one APIM backend per `(instance, model)`, so a throttled deployment only disables that backend while sibling deployments continue serving traffic.
- One PAYG backend pool is created per model, named `{model-clean}-payg-pool` after removing `.` and `-` from the model name; all instances serving that model join the same pool for APIM load balancing.
- The shared [`per-model-routing`](../modules/apim/per-model-routing-fragment.xml) policy fragment is wired into both `/inference/openai` and `/azure`. It reads the model from `/deployments/{name}/...` or the request body's `model`, computes `model-clean`, and routes to the matching pool.
- APIM's system-assigned managed identity is granted **Cognitive Services User** on every backing instance, including instances in other resource groups or subscriptions.

The gateway does not enforce quotas, JWT validation, or access contracts; those controls live in the `ai-gateway-quota` sample. The spec-backed `/azure` API renders the APIM test console and model-discovery endpoints from the synthesized in-deployment OpenAI instance.

## Advanced features

### Anthropic (Claude) models

If you add an Anthropic-format deployment to `openAiDeploymentSpecs` (e.g. `{ name: 'claude-haiku-4-5', format: 'Anthropic', ... }`), [`multi-foundry-backends.bicep`](../modules/apim/advanced/multi-foundry-backends.bicep) automatically routes that backend at `{endpoint}anthropic` instead of `{endpoint}openai`. The same gateway transparently serves both `/deployments/{name}/chat/completions` (OpenAI shape) and `/v1/messages` (Anthropic shape).

### Optional inbound JWT validation (`acceptedTenantIds`)

By default the gateway is open — callers reach it anonymously and APIM's managed identity authenticates outbound to Foundry. Set `acceptedTenantIds` to a non-empty list of tenant IDs to require `Authorization: Bearer <token>` on every inbound call with `aud=https://cognitiveservices.azure.com` and an `iss` matching one of the configured tenants (both v1 `sts.windows.net/{tid}/` and v2 `login.microsoftonline.com/{tid}/v2.0` issuers are accepted). Defaults to `[]` for backward compatibility.

> Note: APIM-to-APIM chaining is not available in this sample because `foundryInstances` is synthesized locally from the in-deployment OpenAI account rather than discovered via `EXISTING_FOUNDRY_RESOURCE_IDS`. Use any other gateway variant for chaining.

## Deployment

```bash
cd options-infra/ai-gateway-pe-custom
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

- **Self-contained testing**: Provision APIM and a test OpenAI account together
- **Private APIM access**: Use Standardv2 with a private endpoint while retaining External VNet injection
- **Per-model routing validation**: Exercise routing pools without external resource prerequisites
- **Private tool integration**: Publish MCP/OpenAPI services alongside model APIs

## Variants

| Sample | Difference |
|--------|------------|
| [ai-gateway-basic](../ai-gateway-basic/) | Public APIM Basicv2, no VNet at all |
| [ai-gateway](../ai-gateway/) | Public APIM Basicv2 with private Foundry dependencies |
| [ai-gateway-internal](../ai-gateway-internal/) | Developer SKU with internal VNet injection and per-instance upstream private endpoints |
| [ai-gateway-pe](../ai-gateway-pe/) | Standardv2 with external VNet injection plus APIM private endpoint and external Foundry fan-out |
| [ai-gateway-premium](../ai-gateway-premium/) | Premiumv2 internal VNet, custom domain, dedicated APIM VNet |
