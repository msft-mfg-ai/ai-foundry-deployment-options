# Foundry Workshop

A fully automated Azure AI Foundry workshop environment for **N participants**. Deploys a shared Foundry account with per-participant projects, an APIM AI Gateway, AI Search with pre-populated indexes, an MCP server, and pre-configured agents — all in a single `azd up`.

## Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────────────────────────┐
│                               Resource Group (this deployment)                             │
│                                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐                  │
│  │                        AI Foundry Account                            │                  │
│  │                                                                      │                  │
│  │  ┌────────────────────────────────────────────────────────────────┐  │                  │
│  │  │  Project(s) with Capability Hosts (1 per participant + trainer)│  │                  │
│  │  │  - Pre-created Agents (v1 + v2 SDKs)                          │  │                  │
│  │  │  - AI Search connection                                        │  │                  │
│  │  │  - Bing Grounding connection                                   │  │                  │
│  │  │  - MCP server connection                                       │  │                  │
│  │  └────────────────────────────────────────────────────────────────┘  │                  │
│  │                                                                      │                  │
│  │  Models: gpt-4o, gpt-5.1, gpt-5, gpt-5-mini, text-embedding-3-large│                  │
│  └──────────────────────────────────────────────────────────┬───────────┘                  │
│                                                             │                              │
│       ┌─────────────────────────────────────────────────────▼───────────────────────┐      │
│       │   Azure API Management (AI Gateway)                                         │      │
│       │   - Per-project managed identity auth                                       │      │
│       │   - Rate limiting / Token metrics                                           │      │
│       │   - Application Insights logging                                            │      │
│       └─────────────────────────────────────────────────────────────────────────────┘      │
│                                                                                            │
│  ┌───────────────────────┐  ┌───────────────────────┐  ┌────────────────────────────────┐ │
│  │  AI Search (Standard) │  │  Storage Account       │  │  Container Apps (MCP Server)   │ │
│  │  - documents index    │  │  - PDFs (data blob)    │  │  - sample-mcp-fastmcp-python   │ │
│  │  - good-books-azd     │  │  - Managed Identity    │  │  - Exposed via APIM            │ │
│  │  - indexer pipeline   │  │                        │  │  - Connected to all projects   │ │
│  └───────────────────────┘  └────────────────────────┘  └────────────────────────────────┘ │
│                                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐  │
│  │  Monitoring: Log Analytics │ Application Insights │ Token Usage Dashboard             │  │
│  └──────────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

## What Gets Deployed

| Category | Resources |
|----------|-----------|
| **AI Foundry** | Account with managed identity, N+1 projects (participants + trainer), Capability Hosts |
| **Models** | `gpt-4o`, `gpt-5.1`, `gpt-5`, `gpt-5-mini`, `text-embedding-3-large` |
| **AI Gateway** | APIM with per-project auth, rate limiting, and token usage metrics |
| **AI Search** | Standard tier with semantic search, vector indexes, document indexer pipeline |
| **Storage** | Blob storage with PDF documents for indexing |
| **MCP Server** | Container App running a sample MCP server, exposed through APIM |
| **Connections** | AI Search, Bing Grounding, and MCP connections shared to all projects |
| **Monitoring** | Log Analytics, Application Insights, APIM Token Usage Dashboard |
| **Agents** | Pre-created agents using both v1 and v2 Azure AI SDKs |

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [uv](https://docs.astral.sh/uv/) — Python package manager (required for post-deployment hooks that create search indexes and agents)
- An Azure subscription with permissions to create resources

## Parameters

Parameters are passed via environment variables, which `main.bicepparam` reads at deployment time.

| Environment Variable | Bicep Parameter | Required | Description |
|---------------------|----------------|----------|-------------|
| `PROJECTS_COUNT` | `projectsCount` | No (default: `1`) | Number of participant projects to create. An extra "trainer" project is always added. |
| `AZURE_PRINCIPAL_ID` | `deployerPrincipalId` | No | Object ID of the deployer's Azure AD principal. Used for RBAC assignments (e.g., Search Index Data Contributor). |
| `AZURE_GROUP_PRINCIPAL_ID` | `groupPrincipalId` | No | Object ID of an Entra ID security group containing all participants. Grants Reader on the resource group and Azure AI Owner on the Foundry account. |
| `STUDENTS_INITIALS` | `studentsInitials` | No | Comma-separated list of participant initials (e.g., `"jsa,adb,mba"`). When provided, project names include the initials for easy identification. **Must match `PROJECTS_COUNT` exactly.** |

## Deployment

```bash
cd options-infra/foundry-workshop

# Set parameters (adjust as needed)
export PROJECTS_COUNT=5
export AZURE_PRINCIPAL_ID="<your-object-id>"
export AZURE_GROUP_PRINCIPAL_ID="<entra-group-object-id>"
export STUDENTS_INITIALS="jsa,adb,mba,kkp,rts"

# Deploy everything
azd up
```

The deployment runs in two phases:

1. **Provision** (`azd provision`) — deploys all Azure infrastructure via Bicep, then runs `postprovision` hooks:
   - Approves pending private endpoint connections for Storage and Foundry
   - Creates AI Search indexes: `documents` (vector + semantic), `good-books-azd` (simple)
   - Sets up the document indexer pipeline with Document Intelligence

2. **Post-up** (`postup` hooks) — after full deployment:
   - Creates agents using the `azure-ai-agents` SDK (v1)
   - Creates agents using the `azure-ai-projects` SDK (v2)
   - Prints the Foundry Portal URL to access the projects

## Outputs

| Output | Description |
|--------|-------------|
| `FOUNDRY_NAME` | Name of the Foundry account |
| `FOUNDRY_PROJECTS_CONNECTION_STRINGS` | Connection strings for all projects |
| `FOUNDRY_PROJECT_NAMES` | Names of all deployed projects |
| `AI_SEARCH_SERVICE_PUBLIC` | Public endpoint of the AI Search service |
| `AI_SEARCH_NAME` | Name of the AI Search service |
| `AI_PROJECT_CONNECTION_STRING` | Connection string for the first project |
| `FOUNDRY_OPENAI_ENDPOINT` | Azure OpenAI endpoint for the Foundry account |
| `INITIALS_USED` | Whether student initials were used for project naming |

## Use Cases

- **Hands-on workshops**: Spin up isolated Foundry projects for each participant with shared infrastructure
- **AI Agents training**: Pre-configured agents and MCP server ready for experimentation
- **RAG/Search labs**: Pre-populated AI Search indexes with vector and semantic search
- **AI Gateway demos**: Centralized model access with per-project rate limiting and monitoring
