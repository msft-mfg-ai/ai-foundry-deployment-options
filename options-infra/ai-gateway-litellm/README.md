# Option: LiteLLM Gateway with AI Foundry

This deployment option creates a complete AI Foundry environment with LiteLLM as a Model Gateway proxy.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                              This Deployment                                            │
│                                                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐                │
│  │                      AI Foundry                                     │                │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                  │                │
│  │  │  Project 1  │  │  Project 2  │  │  Project 4  │                  │                │
│  │  │ + CapHost   │  │ + CapHost   │  │ + CapHost   │                  │                │
│  │  │             │  │             │  │             │                  │                │
│  │  │ Agent Svc ──┼──┼─────────────┼──┼─────────────┼───┐              │                │
│  │  └─────────────┘  └─────────────┘  └─────────────┘ Private Endpoint │                │
│  └──────────────────────────────────────────────────────┼──────────────┘                │
│                                                         │                               │
│                                                         ▼                               │
│  ┌──────────────┐                          ┌──────────────────────┐                     │
│  │ Application  │────(Admin UI)──────────▶│      LiteLLM         │                     │
│  │   Gateway    │                          │    (ACA + PgSQL)     │                     │
│  │  (Public IP) │                          │    Model Gateway     │                     │
│  └──────────────┘                          └──────────┬───────────┘                     │
│                                                       │                                 │
│  ┌────────────────────────────────────────────────────┼─────────────────────────────┐   │
│  │                    Supporting Services             │                             │   │
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

### Foundry
- **Foundry account** with managed identity
- **3 Foundry projects** (Projects 1, 2, and 4) with Capability Hosts in Foundry Standard mode
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

## Run LiteLLM with Docker Compose

For local/self-managed LiteLLM, use the Compose file in `gateway/docker-compose.yml`.

### Required environment variables

Create `.env` from the example file and fill all required values:

```bash
cd options-infra/ai-gateway-litellm/gateway
cp .env.example .env
```

Required values in `.env`:

```env
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=change-me-strong-password

LITELLM_MASTER_KEY=sk-your-master-key
UI_USERNAME=admin
UI_PASSWORD=change-me-ui-password

AZURE_API_BASE=https://your-resource.openai.azure.com
AZURE_API_KEY=your-azure-openai-api-key
```

Variables used by Compose:
- `POSTGRES_DB` - PostgreSQL database name for LiteLLM
- `POSTGRES_USER` - PostgreSQL username
- `POSTGRES_PASSWORD` - PostgreSQL password
- `LITELLM_MASTER_KEY` - LiteLLM master key for API authentication
- `UI_USERNAME` - LiteLLM Admin UI username
- `UI_PASSWORD` - LiteLLM Admin UI password
- `AZURE_API_BASE` - Azure OpenAI endpoint (used by `gateway/config.yaml`)
- `AZURE_API_KEY` - Azure OpenAI API key (used by `gateway/config.yaml`)

### Start the stack

```bash
cd options-infra/ai-gateway-litellm/gateway

# Required once if the external network does not exist yet
docker network create traefik-net

docker compose up -d
```

You do need to provide these values either via `.env` (recommended) or via exported shell environment variables before `docker compose up`.

### Stop the stack

```bash
cd options-infra/ai-gateway-litellm/gateway
docker compose down
```

Notes:
- The Compose file expects an external Docker network named `traefik-net`.
- LiteLLM is exposed to Traefik on port `4000` (service internal port).
- The configured host rule is `litellm.domain.com`; update the Traefik label in `gateway/docker-compose.yml` if you use a different domain.

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
