# Copilot Instructions

## Project Overview

This repository provides **Bicep templates for deploying Microsoft Azure AI Foundry** with various network and infrastructure configurations. It includes 30+ deployment options covering private networking, multi-region, multi-subscription, AI Gateway (APIM), and shared resource patterns.

## Repository Structure

```
/
├── options-infra/          # All Bicep deployment templates
│   ├── modules/            # Reusable Bicep modules (ai, apim, db, iam, networking, storage, types, ...)
│   ├── foundry-basic/      # Minimal self-contained Foundry deployment
│   ├── foundry-*/          # Foundry deployment variants
│   ├── ai-gateway*/        # AI Gateway (APIM) deployment variants
│   ├── shared-infra/       # Shared Cosmos DB, Storage, AI Search
│   └── bicepconfig.json    # Bicep linter config (applies to all templates via inheritance)
├── agents/                 # v1 agent test scripts and notebooks (Python 3.11, own venv)
├── agents_v2/              # v2 agent test scripts and notebooks (Python 3.13, own venv)
├── agents_v2_maf/          # Multi-agent framework test notebooks (own venv)
├── agents_v2_maf_csharp/   # C# agent framework tests (.NET)
├── subscription-manager/   # FastAPI web app for APIM subscription management (own venv)
├── utils/                  # Network-secured agent setup notebooks and HTTP test files
└── .github/
    ├── workflows/          # GitHub Actions CI (one workflow per deployment option)
    └── chatmodes/          # VS Code Copilot chat mode definitions
```

## Validating Bicep Locally

```bash
# Lint a single deployment option (most common)
az bicep lint --file options-infra/<option>/main.bicep

# Build (catches syntax/type errors before lint)
az bicep build --file options-infra/<option>/main.bicep
```

CI uses a standalone `bicep` binary (see `.github/workflows/bicep-validate-reusable.yml`); locally `az bicep` is available.

## Running Python / Agent Scripts

Each agent directory (`agents/`, `agents_v2/`, `agents_v2_maf/`, `subscription-manager/`) is an **isolated Python workspace** — it has its own `pyproject.toml`, `uv.lock`, and `.venv`. They are excluded from the root `pyproject.toml` workspace.

```bash
# Per-directory setup (do this once per directory)
cd agents_v2
uv sync
cp .env.example .env   # then fill in your Azure values

# Run a script
uv run python create_agents.py

# For notebooks: in VSCode select the .venv from that specific directory as the kernel
```

## Deploying a Template

```bash
cd options-infra/<option>
azd up
# Or with az CLI:
az deployment group create \
  --resource-group "<rg-name>" \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Bicep Conventions

- **Naming**: `resourceToken = toLower(uniqueString(resourceGroup().id, location))` for all unique resource names
- **Parameters**: `location` defaults to `resourceGroup().location`; optional params use `string = ''` and are checked with `!empty()`
- **Local param files** (`*.local.bicepparam`) are git-ignored — copy from `main.bicepparam` for local use
- **Parameter validation**: use `var valid = condition ? fail('message') : true` at the top of `main.bicep` to validate required parameter combinations
- **Shared types**: `options-infra/modules/types/types.bicep` exports `aiDependenciesType`, `DnsZonesType`, `dependencyInfoType`, etc. — import with `import * as types from '../types/types.bicep'`
- **Exporting types from modules**: mark with `@export()` and import in callers with `import { TypeName } from 'module.bicep'`

## APIM Module Architecture

The AI Gateway stack has three layers:

```
ai-gateway-pe.bicep  (orchestrator: wires Foundry + APIM + connections)
  └── apim.bicep     (wrapper: creates APIM instance + one or more inference APIs)
        ├── v2/apim.bicep           (APIM service resource + subscriptions + loggers)
        └── v2/inference-api.bicep  (APIM API, backends, backend pool, policy, diagnostics)
```

- **Policy XML files** live in `modules/apim/` (e.g., `policy.xml`, `anthropic-policy.xml`). They use `{backend-id}` and `{retry-count}` as string tokens replaced in Bicep variables before being passed to `inference-api.bicep`.
- **Multiple inference APIs** on one APIM instance (e.g., OpenAI + Anthropic) are created as separate `inference-api.bicep` deployments with `dependsOn` to avoid a tag race condition.
- **Foundry connections** (`modules/ai/connection-apim-gateway.bicep`) set `category: 'ApiManagement'` with a `metadata` object containing `deploymentInPath`, `inferenceAPIVersion`, and either `staticModels` or `modelDiscovery` — never both.

## Private Endpoint Convention

All private endpoints go through `modules/networking/ai-pe-dns.bicep`, which creates the endpoint **and** handles three DNS zones at once (`privatelink.services.ai.azure.com`, `privatelink.openai.azure.com`, `privatelink.cognitiveservices.azure.com`). Pass `existingDnsZones: ai_dependencies.outputs.DNS_ZONES` to reuse already-deployed zones.

## CI/CD Workflows

- **One workflow per deployment option** (e.g., `bicep-foundry-basic.yml`)
- All call `.github/workflows/bicep-validate-reusable.yml` which runs `bicep build` + `bicep lint`
- Path triggers: `options-infra/<option>/**`, `options-infra/modules/**`, `bicep-validate-reusable.yml`
- Copilot setup: `.github/workflows/copilot-setup-steps.yml` installs `azd` and authenticates to Azure

### Adding a new deployment option
1. Create `options-infra/<new-option>/` with `main.bicep`, `main.bicepparam`, `azure.yaml`, `README.md`
2. Reuse modules from `options-infra/modules/`
3. Add `.github/workflows/bicep-<new-option>.yml` calling `bicep-validate-reusable.yml`

## Key Design Patterns

- **BYO Resources**: Templates accept existing Cosmos DB, Storage, AI Search, and VNet via parameters
- **Shared infrastructure**: `shared-infra/` deploys dependencies shared across multiple Foundry accounts
- **Multi-subscription**: `foundry-multi-subscription*` options use subscription-scoped deployments
- **Capability hosts**: Agent Service requires capability hosts at both account and project level; run `destroy-caphost` before deleting Foundry accounts

## Important Constraints

- Secrets must **never** appear in Bicep outputs or default parameter values (`outputs-should-not-contain-secrets` and `secure-parameter-default` are **errors** in `bicepconfig.json`)
- `*.local.bicepparam` files are git-ignored — do not commit them
- Cosmos DB, Storage, and AI Search must be in the **same subscription** as the Foundry account (different resource groups are OK)
- The agent subnet must be **exclusively** delegated to `Microsoft.App/environments`

## subscription-manager

`subscription-manager/` is a standalone FastAPI app with its own copilot instructions at `subscription-manager/.github/copilot-instructions.md`. See that file for its commands, architecture, and testing patterns.
