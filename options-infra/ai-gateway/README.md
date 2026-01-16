# Option: AI Gateway (External APIM) with AI Foundry

This deployment option creates an AI Foundry environment with an **external Azure API Management (APIM) Basic v2** instance acting as an AI Gateway to proxy requests to an external Azure OpenAI resource.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry                                  │                     │
│  │  ┌─────────────────────────────────────────────────────────────┐ │                     │
│  │  │  Project(s) with Capability Hosts                           │ │                     │
│  │  │                                                             │ │                     │
│  │  │  Agent Service ─────────────────────────────────────────────┼─┼──┐                  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │                  │
│  └──────────────────────────────────────────────────────────────────┘  │                  │
│                                                                        │                  │
│                                                                        ▼                  │
│                                              ┌─────────────────────────────────────────┐  │
│                                              │   Azure API Management (External)       │  │
│                                              │   - AI Gateway                          │  │
│                                              │   - Public IP                           │  │
│                                              │   - Static Model Definitions            │  │
│                                              │   - Rate Limiting / Policies            │  │
│                                              └──────────────────┬──────────────────────┘  │
│                                                                 │                         │
│  ┌──────────────────────────────────────────────────────────────┼───────────────────────┐ │
│  │                    Supporting Services                       │                       │ │
│  │  VNet │ Key Vault │ Log Analytics │ App Insights │ Private DNS                       │ │
│  └──────────────────────────────────────────────────────────────┼───────────────────────┘ │
└─────────────────────────────────────────────────────────────────┼─────────────────────────┘
                                                                  │
                                          (Public Internet)       │
                                                                  ▼
                                ┌──────────────────────────────────────────────┐
                                │    External: Azure OpenAI (Landing Zone)     │
                                │                                              │
                                │    Models:                                   │
                                │    - gpt-4.1-mini                            │
                                │    - gpt-5-mini                              │
                                │    - o3-mini                                 │
                                └──────────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service calls the external APIM AI Gateway
2. APIM proxies requests over public internet to Azure OpenAI
3. APIM uses managed identity for authentication to Azure OpenAI

## Deployed Resources

### Networking
- **Virtual Network** with subnets for:
  - Private Endpoints
  - Agent services
- **Private DNS Zones** for:
  - Key Vault, Storage, Cosmos DB, AI Search

### AI Foundry
- **AI Foundry Hub** with managed identity (or use existing)
- **AI Project(s)** with Capability Hosts (configurable count)
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints

### AI Gateway (APIM)
- **Azure API Management** in external mode (public IP)
- Pre-configured static model definitions:
  - `gpt-4.1-mini`
  - `gpt-5-mini`
  - `o3-mini`
- Managed identity with Cognitive Services User role on external OpenAI

### Monitoring
- **Log Analytics Workspace**
- **Application Insights** for APIM and Foundry telemetry

## Prerequisites

Set the following environment variables before deployment:

```bash
export OPENAI_API_BASE="https://your-landing-zone-openai.openai.azure.com"
export OPENAI_RESOURCE_ID="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<openai-name>"
```

### Optional Parameters
- `OPENAI_LOCATION` - Location of the OpenAI resource (defaults to deployment location)
- `EXISTING_FOUNDRY_NAME` - Use an existing AI Foundry hub instead of creating new
- `PROJECTS_COUNT` - Number of AI Projects to create (default: 1)

## Deployment

```bash
cd options-infra/option_ai-gateway
azd up
```

## Outputs

| Output | Description |
|--------|-------------|
| `project_connection_strings` | Connection strings for AI Projects |
| `project_names` | Names of the deployed AI Projects |
| `FOUNDRY_NAME` | Name of the AI Foundry hub |
| `config_validation_result` | Validation status of the configuration |

## Key Differences from `option_ai-gateway-internal`

| Feature | `option_ai-gateway` | `option_ai-gateway-internal` |
|---------|---------------------|------------------------------|
| APIM Mode | External (public IP) | Internal (VNet only) |
| OpenAI Access | Via public internet | Via private endpoint |
| Network Security | Public accessible | Fully private |
| Use Case | Dev/Test, simpler setup | Enterprise/Production |

## Use Cases

- **Development/Testing**: Quick setup without private networking complexity
- **Centralized AI Gateway**: Single point of control for AI model access
- **Landing Zone integration**: Connect to shared Azure OpenAI in a hub subscription
- **Policy enforcement**: Rate limiting, logging, and access control via APIM policies
- **Existing Foundry**: Can attach to an existing AI Foundry hub
