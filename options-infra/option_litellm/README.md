# Option: LiteLLM Gateway with AI Foundry

This deployment option creates a complete AI Foundry environment with LiteLLM as a Model Gateway proxy.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              This Deployment                                             │
│                                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐                   │
│  │                      AI Foundry Hub                               │                   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐               │                   │
│  │  │  Project 1  │  │  Project 2  │  │  Project 4  │               │                   │
│  │  │ + CapHost   │  │ + CapHost   │  │ + CapHost   │               │                   │
│  │  │             │  │             │  │             │               │                   │
│  │  │ Agent Svc ──┼──┼─────────────┼──┼─────────────┼───┐           │                   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘   │           │                   │
│  └──────────────────────────────────────────────────────┼───────────┘                   │
│                                                         │                                │
│                                                         ▼                                │
│  ┌──────────────┐                          ┌──────────────────────┐                     │
│  │ Application  │────(Admin UI)───────────▶│      LiteLLM         │                     │
│  │   Gateway    │                          │    (ACA + PgSQL)     │                     │
│  │  (Public IP) │                          │    Model Gateway     │                     │
│  └──────────────┘                          └──────────┬───────────┘                     │
│                                                       │                                  │
│  ┌────────────────────────────────────────────────────┼─────────────────────────────┐   │
│  │                    Supporting Services             │                              │   │
│  │  VNet │ Key Vault │ Log Analytics │ App Insights │ Private DNS                   │   │
│  └────────────────────────────────────────────────────┼─────────────────────────────┘   │
└───────────────────────────────────────────────────────┼─────────────────────────────────┘
                                                        │
                                                        ▼
                              ┌──────────────────────────────────────────┐
                              │      External: AI Foundry Landing Zone   │
                              │                                          │
                              │  ┌────────────────────────────────────┐  │
                              │  │  Azure OpenAI / AI Services        │  │
                              │  │  (Shared Models)                   │  │
                              │  │  - gpt-4.1-mini                    │  │
                              │  │  - gpt-5-mini                      │  │
                              │  │  - o3-mini                         │  │
                              │  └────────────────────────────────────┘  │
                              └──────────────────────────────────────────┘
```

**Flow:**
1. Foundry Agent Service (in Projects) calls LiteLLM for model inference
2. LiteLLM proxies requests to external AI Foundry Landing Zone
3. Application Gateway provides public access to LiteLLM Admin UI

## Deployed Resources

### Networking
- **Virtual Network** with subnets for:
  - Private Endpoints
  - Azure Container Apps
  - Application Gateway
  - Agent services
- **Private DNS Zones** for:
  - Azure Container Apps (`privatelink.{location}.azurecontainerapps.io`)
  - PostgreSQL (`privatelink.postgres.database.azure.com`)
  - Key Vault, Storage, Cosmos DB, AI Search

### AI Foundry
- **AI Foundry Hub** with managed identity
- **3 AI Projects** (Projects 1, 2, and 4) with Capability Hosts in Foundry Standard mode
- **AI Dependencies**: Storage, Cosmos DB, AI Search with private endpoints

### LiteLLM Gateway
- **Azure Container Apps** environment running LiteLLM proxy
- **PostgreSQL Flexible Server** for LiteLLM database (model configs, spend tracking)
- **Key Vault** for storing API keys and secrets
- Pre-configured models:
  - `azure-gpt-4.1-mini`
  - `azure-gpt-5-mini`
  - `azure-o3-mini`

### Public Access
- **Application Gateway** with public IP for external access to LiteLLM
- Routes traffic to the internal LiteLLM Container App

### Monitoring
- **Log Analytics Workspace**
- **Application Insights** with OpenTelemetry integration for LiteLLM

## Prerequisites

Set the following environment variables before deployment:

```bash
export OPENAI_API_KEY="your-azure-openai-api-key"
export OPENAI_API_BASE="https://your-resource.openai.azure.com"
```

## Deployment

```bash
cd options-infra/option_litellm
azd up
```

## Outputs

| Output | Description |
|--------|-------------|
| `project_connection_strings` | Connection strings for AI Projects 1-3 |
| `project_names` | Names of the deployed AI Projects |
| `config_validation_result` | Validation status of the configuration |

## Use Cases

- **AI Gateway**: Centralized proxy for multiple AI model endpoints
- **Cost Tracking**: LiteLLM provides spend logging and analytics
- **Model Abstraction**: Route requests to different models via unified API
- **AI Foundry Integration**: Projects can use LiteLLM as their AI backend
