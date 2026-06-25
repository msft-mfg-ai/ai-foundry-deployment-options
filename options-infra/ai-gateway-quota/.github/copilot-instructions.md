# Copilot Instructions — `ai-gateway-quota`

This file complements two existing guides — read them first:
- **`AGENTS.md`** (this directory) — canonical policy stack, fragments, backend topology, headers, tests
- **`../../.github/copilot-instructions.md`** (repo root) — Bicep conventions, APIM module architecture, repo-wide patterns

## Deploy / Validate / Test commands

```bash
# Deploy (Bicep, primary path)
AZD_DISABLE_AGENT_DETECT=1 azd up

# Lint / build a single Bicep file before push
az bicep build --file main.bicep
az bicep lint  --file main.bicep
az bicep build --file dashboard/dashboard.bicep
az bicep build --file entra/entra-apps-dynamic.bicep

# Live validation against a deployed env (reads creds from `azd env`)
cd tests
uv sync
uv run pytest -v

# Get a bearer token for a single team (reads secret from azd env)
python scripts/generate_token.py --from-azd alpha --decode
```

The pytest suite at `options-infra/ai-gateway-quota/tests/` covers chat, TTS, Whisper, quota, contract, and failover scenarios.

## Deployment lifecycle (azd hooks)

Defined in `azure.yaml`:

1. **preprovision** — captures `CURRENT_USER_OBJECT_ID` and runs `options-infra/scripts/preprovision-list-foundry-models.sh` to discover Foundry/APIM instances and deployments. The hook writes `FOUNDRY_INSTANCES_JSON`; `main.bicepparam` reads it with `json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))`.
2. **Bicep deploy** — creates Entra app regs, Log Analytics, Event Hub, APIM, contract blob, dashboard, backend pools, fragments, and role assignments.
3. **postprovision** — runs `scripts/add_app_reg_secrets.sh`, then regenerates `.env` from `azd env get-values`.

## Access contracts — central abstraction

Contracts live in `main.bicepparam` and are typed by `../modules/apim/advanced/types.bicep` (`accessContractType`). One contract per caller team:

- `name` — counter key and `x-caller-name`.
- `priority: 1 | 2` — **1 = Production** (`{model}-pool`, mixed PTU+PAYG), **2 = Standard** (`{model}-payg-pool`, PAYG only).
- `identities: []` — deploy dynamically creates an Entra app reg; populate to bring your own app / MI / OID.
- `models[]` — allow-list with per-model `tpm` and optional `ptuTpm`.
- `monthlyQuota` — P1 with 100% PTU is exempt; partial-PTU and P2 are enforced.

Contracts are compiled into a JSON blob and loaded by the `caller-identity` fragment when `contractsBlobUrl` is set. Open mode leaves `contractsBlobUrl` empty so neutral defaults bypass quota blocks.

## Canonical policy stack

- `policy-per-model.xml` is the only canonical inference policy. It applies to the passthrough `inference` API, spec-backed `inference-api-azure`, conditional `openai-api-v1`, and static-discovery operations.
- `caller-identity` provides observability in open mode and JWT + blob contract authz in quota mode via `{contracts-load-section}`.
- `per-model-routing` maps `priority == 1` to `{model}-pool`; all other callers go to `{model}-payg-pool`. PAYG priority is region-aware: in-region 50, out-of-region 100.
- Backends are scoped per `(instance, model, location)` so circuit breakers do not disable unrelated models on the same Foundry.

## Config endpoints

`GET /ai-gateway/config.json` reads contracts, `POST /ai-gateway/config/update` writes them back to blob, and `GET /ai-gateway/config` renders the HTML viewer. Use only these `/ai-gateway/...` paths for config operations.

## Critical deployment constraints

- All Foundry instances serving the same model must use the same deployment name. APIM forwards `/deployments/{name}` unchanged.
- Foundry instances are PTU-only or PAYG-only; `isPtu` determines pool ordering.
- Deploying identity needs `Application.ReadWrite.All` for dynamic Entra app reg creation.
- Keep docs and code references on the current canonical policy stack, blob-backed contract mode, and `/ai-gateway/...` config paths.

## JWT audience

Use `https://cognitiveservices.azure.com/.default` as the MSAL scope. Authorization comes from contract identity matching, not the token audience alone.

## Style

- Bicep params: optional strings use `string = ''` checked with `!empty()`; required combinations use `fail()` validation near the top.
- Resource names: `resourceToken = toLower(uniqueString(resourceGroup().id, location))`.
- Never commit `.env`, `.env.secrets`, `.env.local`, or `tf/terraform.tfvars`.
