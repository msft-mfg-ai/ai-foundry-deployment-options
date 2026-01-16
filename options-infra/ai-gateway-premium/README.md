# Option: AI Gateway (APIM v2 Premium VNet Injection - Internal) with Foundry

This deployment creates a Foundry environment with an **Azure API Management v2 Premium** instance deployed in **VNet Injection mode**, acting as an AI Gateway. The goal is to allow **Foundry Agent Service** to use models from APIM, which proxies requests to an external Azure OpenAI resource.

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
│  │  │  Agent Service ─── Vnet injection ──────────────────────────┼─┼──┐                  │
│  │  └─────────────────────────────────────────────────────────────┘ │  │                  │
│  └──────────────────────────────────────────────────────────────────┘  │                  │
│                                                                        │                  │
│                                                                        ▼                  │
│                                              ┌─────────────────────────────────────────┐  │
│                                              │   Azure API Management v2 Premium        │  │
│                                              │   (VNet Injection Mode)                  │  │
│                                              │   - AI Gateway                           │  │
│                                              │   - Static Model Definitions            │  │
│                                              │   - Load Balancing (future)             │  │
│                                              │   - Rate Limiting / Policies            │  │
│                                              └──────────────────┬──────────────────────┘  │
│                                                                 │                         │
│  ┌──────────────────────────────────────────────────────────────┼───────────────────────┐ │
│  │                    Supporting Services                       │                       │ │
│  │  VNet │ Key Vault │ Log Analytics │ App Insights │ Private DNS │ Private Endpoints   │ │
│  └──────────────────────────────────────────────────────────────┼───────────────────────┘ │
└─────────────────────────────────────────────────────────────────┼─────────────────────────┘
                                                                  │
                                           (Private Endpoint)     │
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
1. Foundry Agent Service calls the internal APIM AI Gateway
2. APIM proxies requests via private endpoint to external Azure OpenAI
3. All traffic stays within private network (no public internet)

## Deployed Resources

### Networking
- **Main Virtual Network** (`192.168.0.0/21`) with subnets for:
  - Private Endpoints
  - Agent services
- **APIM Virtual Network** (`192.168.100.0/23`) with subnets for:
  - APIM v2 Premium (VNet Injection)
- **VNet Peering** between main VNet and APIM VNet
- **Private DNS Zones** for:
  - Azure OpenAI (`privatelink.openai.azure.com`)
  - Key Vault, Storage, Cosmos DB, AI Search
- **Private Endpoint** to external Azure OpenAI resource

### Foundry
- **Foundry account** with managed identity
- **Foundry project(s)** with Capability Hosts (configurable count)
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints

### AI Gateway (APIM v2 Premium)
- **Azure API Management v2 Premium** in VNet Injection mode
- Deployed in a dedicated VNet (`192.168.100.0/23`) peered with the main VNet
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
- `EXISTING_FOUNDRY_NAME` - Use an existing Foundry account instead of creating new
- `PROJECTS_COUNT` - Number of Foundry projects to create (default: 1)

## Deployment

```bash
cd options-infra/option_ai-gateway-internal
azd up
```

## Outputs

| Output | Description |
|--------|-------------|
| `project_connection_strings` | Connection strings for Foundry projects |
| `project_names` | Names of the deployed Foundry projects |
| `FOUNDRY_NAME` | Name of the Foundry account |
| `config_validation_result` | Validation status of the configuration |

## Key Differences from Other Options

| Feature | `option_ai-gateway` | `option_ai-gateway-internal` | `option_ai-gateway-premium` |
|---------|---------------------|------------------------------|------------------------------|
| APIM SKU | v2 Standard | v2 Standard | **v2 Premium** |
| APIM Mode | External (public IP) | Internal (VNet only) | **VNet Injection** |
| Network | Single VNet | Single VNet | **Dedicated APIM VNet + Peering** |
| OpenAI Access | Via public endpoint | Via private endpoint | Via private endpoint |
| Network Security | Public accessible | Fully private | Fully private |

## Use Cases

- **Enterprise/Regulated environments**: All AI traffic stays within private network
- **Centralized AI Gateway**: Single point of control for AI model access
- **Landing Zone integration**: Connect to shared Azure OpenAI in a hub subscription
- **Policy enforcement**: Rate limiting, logging, and access control via APIM policies
