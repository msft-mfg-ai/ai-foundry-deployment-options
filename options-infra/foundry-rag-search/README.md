# Foundry RAG Search

Deploys Azure AI Foundry with AI Search integration, advanced PDF indexing pipeline, and AI agents.

## Description

This deployment creates a comprehensive AI Foundry setup with:
- AI Foundry with VNet integration
- AI Search services:
  - Public without private endpoint
  - Public with private endpoint  
  - Private with private endpoint
- Multiple AI Projects with capability hosts (Foundry Standard mode)
- **Advanced PDF indexing pipeline** with:
  - Document Intelligence for text/table extraction (markdown format)
  - Azure OpenAI GPT-4o for image descriptions
  - Cohere embed-v4 for vector embeddings
  - Semantic search and vector search capabilities
  - Automatic vectorizer for query-time embedding
- Private endpoints for Azure Storage and Cosmos DB

This is useful for building RAG (Retrieval-Augmented Generation) applications with AI Search integrated into your Foundry projects and AI agents.

## Features

- **Multiple Projects**: Configurable number of AI projects (default: 3)
- **AI Search Integration**: Public AI Search service with role assignments
- **Advanced Indexing**: Two approaches for PDF processing:
  - `create_index.py` - Custom Python script with full control over processing
  - `setup_indexer_pipeline.py` - Skillset-based automatic processing (no custom code)
- **Vector Search**: Cohere embed-v4 embeddings with configurable dimensions (256/512/1024/1536)
- **Semantic Search**: Enhanced ranking with semantic configurations
- **Network Isolation**: VNet with dedicated subnets for agents and private endpoints
- **Identity Management**: Managed identities with proper role assignments

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure AI Foundry                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │
│  │ AI Project 1│  │ AI Project 2│  │ AI Project 3│                 │
│  └─────────────┘  └─────────────┘  └─────────────┘                 │
│         │                │                │                         │
│         └────────────────┼────────────────┘                         │
│                          ▼                                          │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    Model Deployments                     │       │
│  │  • GPT-4o (chat, vision)                                │       │
│  │  • text-embedding-ada-002                               │       │
│  │  • Cohere embed-v4 (serverless)                         │       │
│  └─────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure AI Search                              │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    Documents Index                       │       │
│  │  • Vector search (Cohere embeddings)                    │       │
│  │  • Semantic search                                      │       │
│  │  • Vectorizer for query-time embedding                  │       │
│  └─────────────────────────────────────────────────────────┘       │
│                          ▲                                          │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │              Indexer Pipeline (Optional)                 │       │
│  │  • Document Intelligence skillset                       │       │
│  │  • Image analysis skillset                              │       │
│  │  • Embedding skillset                                   │       │
│  └─────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
                                    ▲
                                    │
┌─────────────────────────────────────────────────────────────────────┐
│                      Azure Blob Storage                             │
│                    (PDF documents container)                        │
└─────────────────────────────────────────────────────────────────────┘
```

## Deployment

```bash
# Using Azure Developer CLI (recommended)
azd up

# Using Azure CLI
az deployment group create \
  --resource-group "rg-foundry-search" \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
| `principalId` | User principal ID for role assignments | - |
| `projectsCount` | Number of AI projects to create | 3 |

## Post-Deployment Scripts

After deployment, the `postprovision` hook automatically runs scripts to set up the search index.

### Scripts Overview

| Script | Purpose |
|--------|---------|
| `scripts/create_index.py` | Custom Python script that processes PDFs locally, extracts content using Document Intelligence, generates embeddings, and uploads to Search |
| `scripts/setup_indexer_pipeline.py` | Creates Azure-native indexer pipeline with skillsets for automatic PDF processing |

### Manual Script Usage

**Option 1: Custom Processing (create_index.py)**

```bash
cd scripts
uv sync
uv run python create_index.py \
  --search-endpoint "https://your-search.search.windows.net" \
  --storage-account "yourstorageaccount" \
  --doc-intelligence-endpoint "https://your-cognitive.cognitiveservices.azure.com/" \
  --openai-endpoint "https://your-openai.openai.azure.com/" \
  --pdf-folder "./pdfs" \
  --use-vectors \
  --embedding-endpoint "https://your-cognitive.cognitiveservices.azure.com/" \
  --embedding-deployment "embed-v-4-0" \
  --embedding-dimensions 1536
```

**Option 2: Skillset Pipeline (setup_indexer_pipeline.py)**

```bash
cd scripts
uv sync
uv run python setup_indexer_pipeline.py \
  --search-endpoint "https://your-search.search.windows.net" \
  --storage-account "yourstorageaccount" \
  --doc-intelligence-endpoint "https://your-cognitive.cognitiveservices.azure.com/" \
  --embedding-endpoint "https://your-cognitive.cognitiveservices.azure.com/" \
  --embedding-deployment "embed-v-4-0" \
  --embedding-dimensions 1536 \
  --run-indexer
```

### Required RBAC Roles

For managed identity authentication, ensure the following roles are assigned:

| Resource | Role | Assignee |
|----------|------|----------|
| Storage Account | Storage Blob Data Reader | AI Search managed identity |
| Storage Account | Storage Blob Data Contributor | Your user (for uploads) |
| Cognitive Services | Cognitive Services User | AI Search managed identity |
| Cognitive Services | Cognitive Services OpenAI User | AI Search managed identity |

## Using with AI Agents

The search index includes a **vectorizer** configuration, which allows Azure AI Agent Service to perform vector searches without needing to handle embeddings manually. When connecting your agent to the search index:

1. Create a connection to AI Search in your AI Project
2. Configure your agent to use the `documents` index
3. The vectorizer automatically converts queries to embeddings at search time

```python
# Example: Connecting agent to search
from azure.ai.projects import AIProjectClient

project = AIProjectClient(...)
agent = project.agents.create_agent(
    model="gpt-4o",
    tools=[{"type": "azure_ai_search", "azure_ai_search": {
        "index_connection_id": "your-search-connection",
        "index_name": "documents"
    }}]
)
```
