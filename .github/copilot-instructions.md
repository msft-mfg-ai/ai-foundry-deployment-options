# Copilot Instructions

## Project Overview

This repository provides **Bicep templates for deploying Microsoft Azure AI Foundry** with various network and infrastructure configurations. It includes 29+ deployment options covering private networking, multi-region, multi-subscription, AI Gateway (APIM), and shared resource patterns.

## Repository Structure

```
/
├── options-infra/          # All Bicep deployment templates
│   ├── modules/            # Reusable Bicep modules (ai, apim, db, iam, networking, storage, ...)
│   ├── foundry-basic/      # Minimal self-contained Foundry deployment
│   ├── foundry-*/          # Foundry deployment variants
│   ├── ai-gateway*/        # AI Gateway (APIM) deployment variants
│   ├── shared-infra/       # Shared Cosmos DB, Storage, AI Search
│   └── bicepconfig.json    # Bicep linter configuration (applies to all templates)
├── agents/                 # Python scripts and Jupyter notebooks for testing agents
├── agents_v2/              # Updated agent test scripts
├── subscription-manager/   # FastAPI web app for APIM subscription management
├── utils/                  # Python utility scripts (capability host management)
├── docs/                   # Documentation
└── .github/
    ├── workflows/          # GitHub Actions CI workflows (one per deployment option)
    └── chatmodes/          # VS Code Copilot chat mode definitions
```

## Tech Stack

### Infrastructure (Primary)
- **Language**: [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/) for all IaC
- **Deployment**: `azd up` (Azure Developer CLI) or `az deployment group create`
- **Linter config**: `options-infra/bicepconfig.json` — errors on secrets in outputs/params, warnings on unused vars
- **Each deployment option** has: `main.bicep`, `main.bicepparam`, `azure.yaml`, `README.md`

### Python (Scripts & Agents)
- **Python version**: 3.13+ (see `.python-version`)
- **Package manager**: `uv` (preferred over pip)
- **Workspace**: `pyproject.toml` at root manages the workspace

## Bicep Conventions

- **Modules** are in `options-infra/modules/` and organized by resource type (e.g., `ai/`, `networking/`, `iam/`, `db/`, `storage/`)
- **Naming**: use `resourceToken = toLower(uniqueString(resourceGroup().id, location))` for unique resource names
- **Parameters**: `location` defaults to `resourceGroup().location`; `principalId` is used for RBAC assignments
- **No hardcoded secrets** in outputs or parameters — Bicep linter enforces this as an error
- **Local param files** (`*.local.bicepparam`) are git-ignored; copy from `main.bicepparam` for local use
- **Private DNS zones**: always required when deploying private endpoints; see README for the zone list

## CI/CD Workflows

- **One workflow per deployment option** in `.github/workflows/` (e.g., `bicep-foundry-basic.yml`)
- All workflows reuse `.github/workflows/bicep-validate-reusable.yml` which runs `bicep build` + `bicep lint`
- Workflows trigger on push/PR to `main` when files in the relevant `options-infra/<option>/` or `options-infra/modules/` change
- **Copilot setup** workflow: `.github/workflows/copilot-setup-steps.yml` installs `azd` and logs in to Azure

## Common Tasks

### Adding a new deployment option
1. Create a new directory under `options-infra/<new-option>/`
2. Add `main.bicep`, `main.bicepparam`, `azure.yaml`, and `README.md`
3. Reuse modules from `options-infra/modules/` wherever possible
4. Create a corresponding `.github/workflows/bicep-<new-option>.yml` that calls `bicep-validate-reusable.yml`

### Validating Bicep locally
```bash
# Build (checks for syntax errors)
bicep build options-infra/<option>/main.bicep

# Lint (checks for best-practice violations)
bicep lint options-infra/<option>/main.bicep
```

### Running Python scripts / agents
```bash
# From repo root
uv sync
cd agents
uv run python agent.py
```

### Deploying a template
```bash
cd options-infra/<option>
azd up
# Or with az CLI:
az deployment group create \
  --resource-group "<rg-name>" \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Key Design Patterns

- **BYO Resources**: Templates support Bring-Your-Own Cosmos DB, Storage, AI Search, and VNet via parameters
- **Shared infrastructure**: `shared-infra/` deploys resources that multiple Foundry instances can reference
- **Multi-subscription**: Use `foundry-multi-subscription*` options with subscription-scoped deployments
- **AI Gateway**: APIM-based patterns in `ai-gateway*/` use policy files in `options-infra/ai-gateway*/policies/`
- **Capability hosts**: Agent Service requires capability hosts on both the account and project level; use `destroy-caphost` utility before deleting accounts

## Important Constraints

- Secrets must **never** appear in Bicep outputs or default parameter values (linter error)
- `*.local.bicepparam` files are git-ignored — do not commit local parameter files
- Dependent resources (Cosmos DB, Storage, Search) must be in the **same subscription** as the Foundry account (different resource groups are OK)
- Agent subnet must be **exclusively** delegated to `Microsoft.App/environments` and not shared
