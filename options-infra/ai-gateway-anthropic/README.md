# Option: AI Gateway (APIM Standard v2) with Anthropic / Claude models

> **Unified architecture note:** This is a specialized cross-tenant/API-key Anthropic sample. The unified APIM gateway stack now also supports Anthropic-format deployments through `FOUNDRY_INSTANCES_JSON`, `policy-per-model.xml`, and `per-model-routing`; prefer the unified stack unless you specifically need this API-key backend credential pattern.

This deployment creates a Foundry environment with an **Azure API Management (APIM) v2 Standard** instance acting as an AI Gateway for **Anthropic Claude models** hosted on Azure AI Foundry. It is designed for scenarios where the Anthropic Foundry account is in a **different tenant** from the APIM deployment — authentication uses an API key sent as a backend credential header.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────┐                         │
│  │                      AI Foundry                              │                         │
│  │  ┌─────────────────────────────────────────────────────────┐ │                         │
│  │  │  Project(s) with Capability Hosts                       │ │                         │
│  │  │                                                         │ │                         │
│  │  │  Agent Service ─────────────────────────────────────────┼─┼──┐                      │
│  │  └─────────────────────────────────────────────────────────┘ │  │                      │
│  └──────────────────────────────────────────────────────────────┘  │                      │
│                                                                     │                      │
│                                                                     ▼                      │
│                                              ┌──────────────────────────────────────────┐  │
│                                              │  Azure API Management (Private Endpoint) │  │
│                                              │  - Anthropic pass-through API            │  │
│                                              │    at /inference/anthropic               │  │
│                                              │  - API-key backend credential            │  │
│                                              │  - Retry / rate-limit policies           │  │
│                                              └─────────────────────┬────────────────────┘  │
│                                                                     │                      │
│  ┌──────────────────────────────────────────────────────────────────┼──────────────────┐   │
│  │  VNet │ Key Vault │ Log Analytics │ App Insights │ Private DNS   │ Private Endpoints │   │
│  └──────────────────────────────────────────────────────────────────┼──────────────────┘   │
└────────────────────────────────────────────────────────────────────┼──────────────────────┘
                                                                     │ API key (header)
                                                                     │ over public HTTPS
                                                                     ▼
                                ┌──────────────────────────────────────────────────┐
                                │  External: Azure AI Foundry (Anthropic models)   │
                                │  (may be in a different subscription / tenant)   │
                                │                                                  │
                                │  Models:                                         │
                                │  - claude-opus-4-6                               │
                                └──────────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls the APIM AI Gateway via private endpoint
2. APIM attaches the `api-key` header and forwards to the external Anthropic Foundry endpoint
3. Inbound traffic to APIM stays within the private network; outbound to Anthropic Foundry is HTTPS

## Prerequisites

- An Azure AI Foundry account with Claude models deployed (can be in a different tenant)
- An API key for that Foundry account (`ANTHROPIC_API_KEY`)
- Azure CLI and `azd` installed

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_BASE` | ✅ | Base URL of the Foundry account, e.g. `https://<name>.services.ai.azure.com` |
| `ANTHROPIC_API_KEY` | ✅ | API key for the Foundry endpoint |
| `ANTHROPIC_RESOURCE_ID` | Optional | ARM resource ID of the Foundry account (used as backend metadata only) |
| `ANTHROPIC_LOCATION` | Optional | Azure region of the Foundry account (defaults to deployment location) |
| `APIM_PUBLIC_ENABLED` | Optional | Set to `true` to keep APIM public (default: `false`) |
| `PROJECTS_COUNT` | Optional | Number of Foundry projects to create (default: `1`) |

## Deploy

```bash
cd options-infra/ai-gateway-anthropic

# Set required environment variables
export ANTHROPIC_API_BASE="https://<your-foundry-name>.services.ai.azure.com"
export ANTHROPIC_API_KEY="<your-api-key>"

azd up
```

## Calling the API

After deployment the Anthropic inference endpoint is exposed at:

```
https://<apim-name>.azure-api.net/inference/anthropic/v1/messages
```

Example request using the Anthropic Python SDK:

```python
import anthropic

client = anthropic.Anthropic(
    base_url="https://<apim-name>.azure-api.net/inference/anthropic",
    api_key="<apim-subscription-key>",  # APIM subscription key, not the Anthropic API key
)

message = client.messages.create(
    model="claude-opus-4-6",
    max_tokens=1024,
    messages=[{"role": "user", "content": "Hello, Claude!"}],
)
print(message.content)
```

> **Note:** The APIM subscription key is generated during deployment and stored as a Foundry connection. The Anthropic API key is kept in the APIM backend credentials and never exposed to callers.

## Private DNS Zones Required

The following private DNS zones are created automatically by `ai-dependencies-with-dns.bicep`:

- `privatelink.cognitiveservices.azure.com`
- `privatelink.openai.azure.com`
- `privatelink.api.azureml.ms`
- `privatelink.notebooks.azure.net`
- `privatelink.vaultcore.azure.net`
- `privatelink.blob.core.windows.net`
- `privatelink.search.windows.net`
- `privatelink.documents.azure.com`
