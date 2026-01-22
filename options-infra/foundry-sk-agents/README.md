# SK Agents with Azure AI Foundry

This project contains two containerized applications that work together:

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│   SK Agents App     │────▶│  File Processor API │
│   (Port 3000)       │     │    (Port 3001)      │
├─────────────────────┤     ├─────────────────────┤
│ - Master Agent      │     │ - FastAPI           │
│ - Large Context     │     │ - 3-min delay       │
│   Agent             │     │ - Hardcoded summary │
│ - Web UI            │     │                     │
│ - Semantic Kernel   │     │                     │
└─────────────────────┘     └─────────────────────┘
         │                           │
         └───────────┬───────────────┘
                     ▼
         ┌─────────────────────┐
         │   App Insights      │
         │   (OpenTelemetry)   │
         └─────────────────────┘
```

## Applications

### 1. SK Agents App (`apps/sk-agents/`)

A Semantic Kernel-based application with:

- **Master Agent**: Orchestrates tasks and routes to appropriate plugins
- **Large Context Agent**: Handles file processing by calling the File Processor API
- **Simple Web UI**: Chat interface to interact with the Master Agent
- **Plugins**:
  - `knowledge` - System capabilities and status
  - `large_context_agent` - Delegates to Large Context Agent
  - `file_processor` - Direct file processing

### 2. File Processor App (`apps/file-processor/`)

A FastAPI service that:
- Accepts file lists for processing
- Simulates 3-minute processing delay
- Returns hardcoded summary responses
- Fully instrumented with OpenTelemetry

## Local Development

### Prerequisites

- Docker and Docker Compose
- Azure CLI (for authentication)
- Python 3.11+ (for local development without Docker)

### Quick Start with Docker

1. Copy the environment file:
   ```bash
   cp .env.example .env
   ```

2. Fill in the required values in `.env`:
   - `APPLICATIONINSIGHTS_CONNECTION_STRING` (from Azure portal)
   - `AZURE_AI_PROJECT_CONNECTION_STRING` (from AI Foundry)

3. Run with Docker Compose:
   ```bash
   docker-compose up --build
   ```

4. Access the applications:
   - SK Agents UI: http://localhost:3000
   - File Processor API: http://localhost:3001

### Running Without Docker

1. Start the File Processor:
   ```bash
   cd apps/file-processor
   pip install -r requirements.txt
   PROCESSING_DELAY_SECONDS=10 python main.py  # Shorter delay for testing
   ```

2. Start the SK Agents App:
   ```bash
   cd apps/sk-agents
   pip install -r requirements.txt
   FILE_PROCESSOR_URL=http://localhost:3001 python main.py
   ```

## Deployment to Azure

### Using Azure Developer CLI (AZD)

1. Initialize (if not already done):
   ```bash
   azd init
   ```

2. Provision infrastructure:
   ```bash
   azd provision
   ```

3. Deploy applications:
   ```bash
   azd deploy
   ```

4. Full deployment (provision + deploy):
   ```bash
   azd up
   ```

### Infrastructure Components

The `main.bicep` deploys:
- Azure AI Foundry with project
- Container Apps Environment
- Two Container Apps (sk-agents, file-processor)
- Container Registry
- Application Insights for telemetry
- Virtual Network with subnets
- Managed Identity for authentication

## Environment Variables

### SK Agents App

| Variable | Description | Required |
|----------|-------------|----------|
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights connection | Yes (for telemetry) |
| `AZURE_AI_PROJECT_CONNECTION_STRING` | AI Foundry project connection | Yes |
| `FILE_PROCESSOR_URL` | URL to File Processor service | Yes |
| `AZURE_OPENAI_DEPLOYMENT` | Model deployment name | No (default: gpt-4.1-mini) |

### File Processor App

| Variable | Description | Required |
|----------|-------------|----------|
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights connection | Yes (for telemetry) |
| `PROCESSING_DELAY_SECONDS` | Processing delay in seconds | No (default: 180) |

## API Endpoints

### SK Agents App (Port 3000)

- `GET /` - Web UI
- `GET /health` - Health check
- `POST /invoke` - Invoke master agent
- `GET /api/agents` - List available agents

### File Processor App (Port 3000/3001)

- `GET /` - Service info
- `GET /health` - Health check
- `POST /process-files` - Process files (3-min delay)

## OpenTelemetry Instrumentation

Both apps are instrumented with:
- Trace spans for all operations
- HTTP client instrumentation
- FastAPI request/response tracing
- Custom spans for business logic
- Automatic export to Azure Application Insights

## Example Usage

### Via Web UI

1. Open http://localhost:3000
2. Type a message like: "Summarize these files: report.pdf, data.csv, notes.txt"
3. The Master Agent will delegate to the Large Context Agent
4. Wait ~3 minutes for the File Processor to respond
5. View the summary response

### Via API

```bash
# Invoke the master agent
curl -X POST http://localhost:3000/invoke \
  -H "Content-Type: application/json" \
  -d '{"message": "Summarize these files: report.pdf, data.csv"}'

# Process files directly
curl -X POST http://localhost:3001/process-files \
  -H "Content-Type: application/json" \
  -d '{"files": ["report.pdf", "data.csv"]}'
```

## Troubleshooting

### Common Issues

1. **Agents not initializing**: Check Azure credentials and connection strings
2. **File Processor timeout**: Ensure the delay is appropriate for your timeout settings
3. **No telemetry**: Verify `APPLICATIONINSIGHTS_CONNECTION_STRING` is set correctly

### Viewing Logs

```bash
# Docker logs
docker-compose logs -f sk-agents
docker-compose logs -f file-processor

# Azure Container Apps logs
az containerapp logs show -n aca-agents-xxx -g your-rg --follow
```
