# AGENTS.md — AI Coding Agent Guide

## Project Overview

This project implements the Komatsu-aligned **APIM AI Gateway** for Azure AI Foundry. It provides:

- **Single policy stack**: `options-infra/modules/apim/policy-per-model.xml` is the canonical inference policy for the passthrough `inference` API, spec-backed `inference-api-azure` API, conditional `openai-api-v1` API (Premium/StandardV2 SKUs), and static-discovery operations.
- **Access contract enforcement**: Each caller has a blob-backed contract defining TPM, monthly token quota, priority, and allowed models. Contracts are wired through `caller-identity-fragment.bicep`'s `contractsBlobUrl` parameter.
- **2-tier priority routing**: `priority == 1` routes to `{model}-pool` (mixed PTU+PAYG); other priorities route to `{model}-payg-pool` (PAYG only).
- **PTU + PAYG spillover**: PTU backends are priority 1, in-region PAYG priority 50, out-of-region PAYG priority 100. Circuit breakers isolate failover per `(instance, model, location)` backend.
- **Portal dashboard**: `dashboard/dashboard.bicep` visualizes caller token usage, quota consumption, rate limits, failover counts, and remaining quota from APIM diagnostic headers.

## Directory Structure

```text
ai-gateway-quota/
├── dashboard/               # Azure Portal dashboard (Bicep)
├── tests/                   # Pytest live integration suite
├── docs/                    # Supporting design docs
└── tf/                      # Legacy/experimental Terraform path; verify parity before use

# Shared modules and canonical policies live outside this option:
options-infra/modules/apim/
├── policy-per-model.xml             # Canonical inference policy
├── caller-identity-fragment.xml     # Observability + optional contract authz fragment
├── caller-identity-fragment.bicep   # Injects {contracts-load-section}
├── per-model-routing-fragment.xml   # Priority-aware per-model pool routing
├── per-model-routing-fragment.bicep
├── log-settings.bicep               # Captured request/response headers
├── static-discovery-operations.bicep
├── v2/inference-api.bicep           # Passthrough inference API
├── v2/inference-api-azure.bicep     # Spec-backed Azure API
├── v2/openai-api-v1.bicep           # Conditional OpenAI v1 API
└── advanced/multi-foundry-backends.bicep
```

## Policy Files and Fragments

### `policy-per-model.xml`

Canonical request policy for all inference surfaces. It includes the shared fragments, applies per-model TPM and monthly quota limits only when contract values are present, routes to the selected pool, retries/fails over, and emits observability headers.

### `caller-identity`

`caller-identity-fragment.xml` always sets caller observability headers/variables. `{contracts-load-section}` lets the same fragment run in two modes:

- **Open mode** (`contractsBlobUrl` empty): neutral defaults flow through; `model-tpm` and monthly quota are `0`, so `<llm-token-limit>` blocks in `policy-per-model.xml` short-circuit via `<choose when="model-tpm > 0">` wrappers.
- **Quota mode** (`contractsBlobUrl` set): validates JWT, loads contracts from blob, matches identity, sets caller priority/quotas, and enforces per-model authorization.

### `per-model-routing`

Extracts the requested model from URL/body, computes `model-clean`, and selects the pool:

- `priority == 1` → `{model-clean}-pool` (mixed PTU+PAYG)
- otherwise → `{model-clean}-payg-pool` (PAYG only)

### Config endpoints

- `GET /ai-gateway/config.json` — read current contracts
- `POST /ai-gateway/config/update` — write updated contracts back to blob
- `GET /ai-gateway/config` — styled HTML viewer

## Backend Topology

`advanced/multi-foundry-backends.bicep` creates one APIM backend per `(instance, model, location)`. This scopes circuit breakers per model so one throttled model does not disable other models on the same Foundry instance.

Per model, it creates:

- `{model-clean}-pool` when PTU and PAYG exist: PTU priority 1, in-region PAYG priority 50, out-of-region PAYG priority 100.
- `{model-clean}-payg-pool`: PAYG-only pool for standard/open callers.

## AZD Discovery Flow

Before each `azd up`, `options-infra/scripts/preprovision-list-foundry-models.sh` discovers configured Foundry/APIM instances and their deployments, then writes `FOUNDRY_INSTANCES_JSON` to the azd environment. `main.bicepparam` reads it with:

```bicep
json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))
```

## Captured Headers

`log-settings.bicep` captures these key headers in APIM diagnostics: `x-caller-name`, `x-caller-id`, `x-caller-priority`, `x-caller-identity`, `x-caller-foundry`, `x-caller-project`, `x-backend-id`, `x-backend-pool`, `x-backend-retry-count`, `x-backend-attempt-trail`, `x-inference-failover`, `x-requested-model`, `x-tokens-consumed`, `x-ratelimit-remaining-tokens`, `x-quota-tokens-consumed`, `x-quota-remaining-tokens`, `x-quota-limit-tokens`, `x-ratelimit-limit-tokens`, `x-ptu-limit`, `x-foundry-agent-id`, `x-foundry-project-name`, `x-foundry-project-id`.

## Tests

Live pytest suite:

```bash
cd options-infra/ai-gateway-quota/tests
uv sync
uv run pytest -v
```

The suite covers chat, TTS, Whisper, quota, contract, and failover scenarios.

## Key Gotchas

- `set-variable` is not allowed inside APIM `<backend>` sections.
- PTU capacity exhaustion can return 503 as well as 429; retry/failover logic must handle both.
- `llm-token-limit` is inbound-only and remaining-token headers are estimates on StandardV2.
- `OpenAITokenQuotaExceeded` has a capital **Q**.
- Circuit breaker failures can surface as `PoolIsInactive`.
- Keep canonical policy references on `policy-per-model.xml`, `caller-identity`, and `per-model-routing`; do not revive legacy priority/identity policy artifacts.
