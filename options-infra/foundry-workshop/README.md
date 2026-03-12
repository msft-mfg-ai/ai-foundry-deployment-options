# Option: AI Gateway (External APIM) with Foundry Basic

This deployment creates a Foundry Basic environment with an **external Azure API Management (APIM) Basic v2** instance acting as an AI Gateway. The goal is to allow **Foundry Agent Service** to use models from APIM, which proxies requests to an external Azure OpenAI resource.

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────────────────┐
│                                    This Deployment                                        │
│                                                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐                     │
│  │                      AI Foundry                                  │                     │
│  │  ┌─────────────────────────────────────────────────────────────┐ │                     │
│  │  │  Project(s) with Capability Hosts                           │ │                     │
│  │  │  NO Capability Hosts / NO Agent Subnet                      │ │                     │
│  │  │                                                             │ │                     │
│  │  │  Agent Service (Public traffic, No VNET)   ─────────────────┼─┼──┐                  │
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

### Foundry
- **Foundry account** with managed identity (or use existing)
- **Foundry project(s)** with Capability Hosts (configurable count)

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
- `PROJECTS_COUNT` - Number of Foundry projects to create (default: 1)

## Deployment

```bash
cd options-infra/option_ai-gateway
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
- **Landing Zone integration**: Connect to shared Azure OpenAI in a hub subscription
- **Policy enforcement**: Rate limiting, logging, and access control via APIM policies
