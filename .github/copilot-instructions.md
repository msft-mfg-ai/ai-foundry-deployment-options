# Copilot Instructions

## Project Overview

This repository provides **Bicep templates for deploying Microsoft Azure AI Foundry** with various network and infrastructure configurations. It includes 35+ deployment options covering private networking, multi-region, multi-subscription, AI Gateway (APIM), and shared resource patterns.

### Nested instruction files — read these when working in scope

Several subprojects have their own copilot/agent guides with scope-specific gotchas. **Always read the nested file first** when working under that path:

| Path | File |
|---|---|
| `options-infra/foundry-byo-vnet-teams/` | `.github/copilot-instructions.md` — Teams bots, ABS auth, per-agent app regs, proxy contract |
| `options-infra/ai-gateway-quota/` | `AGENTS.md` — APIM access contracts, PTU/PAYG spillover, policy XML placeholder system |
| `subscription-manager/` | `.github/copilot-instructions.md` — FastAPI app commands, architecture, tests |
| `hosted-agent/` | `README.md` — Foundry Hosted Agent that runs the gateway pytest suite via the Invocations protocol (call it when APIM is PE-locked and public callers get HTTP 403) |

The companion C# proxy for `foundry-byo-vnet-teams` is a separate repo cloned locally at `/home/pkarpala/projects/medline/foundry-teams-bot-service-proxy` (remote: `github.com/karpikpl/foundry-teams-bot-service-proxy`).

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

This repo uses **`uv`** for all Python dependency management — **never** create a `requirements.txt` or use `pip install`. Declare dependencies in a `pyproject.toml` and run with `uv sync` / `uv run`.

Each Python directory (`agents/`, `agents_v2/`, `agents_v2_maf/`, `subscription-manager/`, and per-option `tests/` folders) is an **isolated Python workspace** — it has its own `pyproject.toml`, `uv.lock`, and `.venv`. They are excluded from the root `pyproject.toml` workspace.

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
# IMPORTANT: when running azd from Copilot CLI / other AI agents, prefix with
# AZD_DISABLE_AGENT_DETECT=1 — azd auto-detects coding agents and silently
# switches to --no-prompt, which breaks interactive flows (login, env init).
AZD_DISABLE_AGENT_DETECT=1 azd up

# Or with az CLI:
az deployment group create \
  --resource-group "<rg-name>" \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Cross-cutting deployment scripts (`options-infra/scripts/`)

azd hooks (referenced from individual options' `azure.yaml`) shared across deployments:

- `preprovision-multi-agent.{sh,ps1}` — creates per-agent AAD app regs + secrets, writes them back to azd env vars (`AGENT_APP_REGS_JSON`, `AGENT_APP_SECRETS_JSON`) for bicepparam consumption. Used by `foundry-byo-vnet-teams`.
- `postprovision-multi-agent.{sh,ps1}` — creates FICs on per-agent regs, registers OIDC reply URLs.
- `preprovision-litellm-cert.{sh,ps1}` — generates TLS cert material for LiteLLM gateway.
- `preprovision-sso-app.{sh,ps1}` / `postprovision-sso-test.{sh,ps1}` — shared SSO app reg setup + smoke test.
- `publish-teams-agent.{sh,ps1}` — calls Foundry's `/microsoft365/publish` API; **requires a user-delegated AAD token** (managed identities fail with "Underlying error while obtaining user token"), so it runs as an azd postprovision hook against the developer's `az login` context, not from inside a Bicep `deploymentScript`.

**Shell idempotency gotcha**: `azd env get-value <missing-key>` writes its "key not found" error to **stdout** (not stderr) and exits 1. Always check the exit code, not whether stdout is non-empty:
```bash
val=$(azd env get-value FOO 2>/dev/null) || val=""
```

## Bicep Conventions

- **Naming**: `resourceToken = toLower(uniqueString(resourceGroup().id, location))` for all unique resource names
- **Parameters**: `location` defaults to `resourceGroup().location`; optional params use `string = ''` and are checked with `!empty()`
- **Local param files** (`*.local.bicepparam`) are git-ignored — copy from `main.bicepparam` for local use
- **Parameter validation**: use `var valid = condition ? fail('message') : true` at the top of `main.bicep` to validate required parameter combinations
- **Shared types**: `options-infra/modules/types/types.bicep` exports `aiDependenciesType`, `DnsZonesType`, `dependencyInfoType`, etc. — import with `import * as types from '../types/types.bicep'`
- **Exporting types from modules**: mark with `@export()` and import in callers with `import { TypeName } from 'module.bicep'`

## APIM Module Architecture

The unified AI Gateway stack uses one APIM service with shared fragments, per-model backends, and up to four API surfaces:

```
<sample orchestrator>.bicep
  └── modules/apim/common-apim-setup.bicep or ai-gateway-advanced.bicep
        ├── v2/apim.bicep                 (APIM service + subscriptions + loggers)
        ├── v2/inference-api.bicep        (passthrough `inference` API)
        ├── v2/inference-api-azure.bicep  (spec-backed `inference-api-azure` API)
        ├── v2/openai-api-v1.bicep        (`openai-api-v1`, Premium/StandardV2 only)
        ├── static-discovery-operations.bicep (deploy-time model catalog ops)
        ├── caller-identity-fragment.bicep
        └── per-model-routing-fragment.bicep
```

- **Single policy stack**: `modules/apim/policy-per-model.xml` is canonical for the passthrough `inference` API, spec-backed `inference-api-azure`, conditional `openai-api-v1`, and static-discovery operations. Keep references on the current canonical stack rather than legacy per-provider or priority policies.
- **Policy fragments**: `caller-identity` sets observability headers in open mode and, when `caller-identity-fragment.bicep` receives `contractsBlobUrl`, uses `{contracts-load-section}` to inject JWT validation + blob contract lookup + identity/model authz. `per-model-routing` sends `priority == 1` to `{model}-pool` and other callers to `{model}-payg-pool`.
- **Backend topology**: `advanced/multi-foundry-backends.bicep` creates one backend per `(instance, model, location)`, so circuit breakers are scoped per model. Mixed pools use PTU priority 1 plus PAYG priority 50 in-region / 100 out-of-region; PAYG-only pools serve non-priority callers.
- **AZD discovery flow**: `options-infra/scripts/preprovision-list-foundry-models.sh` runs before each `azd up`, discovers Foundry instances and deployments, writes `FOUNDRY_INSTANCES_JSON`, and `main.bicepparam` reads it with `json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))`.
- **Foundry connections** (`modules/ai/connection-apim-gateway.bicep`) set `category: 'ApiManagement'` with `metadata` containing `deploymentInPath`, `inferenceAPIVersion`, and either `staticModels` or `modelDiscovery` — never both.

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
