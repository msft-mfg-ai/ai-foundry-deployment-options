# Copilot Instructions — `ai-gateway-quota`

This file complements two existing guides — read them first:
- **`AGENTS.md`** (this directory) — policy XML files, placeholder substitution system, key APIM gotchas, dashboard pipeline
- **`../../.github/copilot-instructions.md`** (repo root) — Bicep conventions, APIM module architecture, repo-wide patterns

What follows is the scope-specific information not covered there.

## Deploy / Validate / Test commands

```bash
# Deploy (Bicep, primary path)
# IMPORTANT: prefix azd with AZD_DISABLE_AGENT_DETECT=1 when running from any
# AI coding agent — azd auto-detects agents and silently sets --no-prompt,
# which breaks interactive login / env init.
AZD_DISABLE_AGENT_DETECT=1 azd up

# Deploy (Terraform alternative — uses APIM named values instead of blob storage)
cd tf && terraform apply

# Lint / build a single Bicep file before push
az bicep build --file main.bicep
az bicep lint  --file main.bicep
az bicep build --file dashboard/dashboard.bicep
az bicep build --file entra/entra-apps-dynamic.bicep

# Live validation against a deployed env (reads creds from `azd env`)
cd tests && uv sync           # one-time, isolated venv (Python >= 3.12)
# Open and run tests/test_priority_gateway.ipynb against the live gateway —
# it fetches contracts dynamically from /gateway/config.json, so it adapts
# to whatever access contracts the deployment uses.
uv run python ../scripts/simulate_traffic.py --requests-per-team 10 --model gpt-4.1-mini

# Get a bearer token for a single team (reads secret from azd env)
python scripts/generate_token.py --from-azd alpha --decode
```

There are no unit tests for the XML policies — the contract is the live
`tests/test_priority_gateway.ipynb` notebook. After changing routing/quota
logic, redeploy and re-run the notebook.

## Deployment lifecycle (azd hooks)

Defined in `azure.yaml`:

1. **preprovision** — captures `CURRENT_USER_OBJECT_ID` from `az ad signed-in-user`.
2. **Bicep deploy** — creates Entra app regs (one per contract with empty `identities`), Log Analytics, Event Hub, APIM, contract blob, dashboard, and cross-RG `Cognitive Services User` role assignments from APIM MI to each Foundry account.
3. **postprovision** — runs `scripts/add_app_reg_secrets.sh` (writes `TEAM_<NAME>_SECRET` back into azd env via `az ad app credential reset`), then regenerates `.env` from `azd env get-values`.

The `.env` file is git-ignored and is the single source of truth for the test scripts. Re-run `scripts/generate-env.sh` to refresh it without redeploying.

## Access contracts — the central abstraction

Contracts live in `main.bicepparam` (Bicep) or `tf/terraform.tfvars` (Terraform) and are typed by `../modules/apim/advanced/types.bicep` (`accessContractType`). One contract per caller team:

- `name` — used as the counter-key for TPM / monthly quotas and surfaced as `x-caller-name` header.
- `priority: 1 | 2` — **1 = Production** (mixed PTU+PAYG pool with circuit-breaker failover), **2 = Standard** (PAYG-only pool, always quota-enforced).
- `identities: []` (empty) → the deploy dynamically creates an Entra app reg via the Microsoft Graph Bicep extension in `entra/entra-apps-dynamic.bicep`. Populate the array to bring your own app / MI / OID.
- `models[]` — allow-list with per-model `tpm` (hard 429) and optional `ptuTpm` (soft PTU allocation).
- `monthlyQuota` — see **Quota compromise** in `README.md`: P1 with 100% PTU is *exempt* from monthly quota enforcement; partial-PTU and P2 are always enforced.

Contracts are compiled into either a JSON blob (default, `useStorageAccount=true`) cached 5 min in APIM, or an APIM named value (Terraform default — has a 4096-char limit). Picking the wrong storage mode for a large contract set is a common silent failure.

## Bicep ↔ Terraform parity

Both deploy paths share the same policy XML files in `options-infra/modules/apim/advanced/` via the placeholder system documented in `AGENTS.md`. **The Terraform tree also keeps its own copies under `tf/policies/`** (Terraform `file()` cannot reach outside its module tree cleanly). Any change to a shared XML must be mirrored — they will silently drift otherwise.

Known TF gaps vs Bicep (see `TODO.md`):
- Event Hub logging (`{eventhub-logger-id}` placeholder is empty)
- App Insights integration
- Dashboard (`dashboard/dashboard.bicep` is Bicep-only)

## Critical deployment constraints

- **All Foundry instances serving the same model must use the same deployment name.** APIM backend pools forward the URL path unchanged. A PTU instance with deployment `gpt-4.1-mini-ptu` will produce intermittent 404s when traffic is meant to spill over to a PAYG instance with deployment `gpt-4.1-mini`. The `deployments[].modelName` field is the deployment name (no separate override is supported).
- **Foundry instances are PTU-only OR PAYG-only**, never mixed. `isPtu: true|false` determines pool ordering automatically.
- **Deploying identity needs `Application.ReadWrite.All`** for the dynamic Entra app reg creation. The preprovision step fails fast if it doesn't.

## JWT audience is `https://cognitiveservices.azure.com`

This is deliberate, not the gateway's own app reg audience. Any Azure AI SDK that already targets Cognitive Services works without token changes; authorization happens via the contract identity match, not the audience. When writing or debugging clients, the MSAL scope is `https://cognitiveservices.azure.com/.default`.

## Public config endpoints

`/gateway/config`, `/gateway/config.json`, and `/gateway/config/refresh` on the APIM gateway are **intentionally unauthenticated**. They expose team names, app IDs, and quotas (no secrets). If a task asks to add auth here, confirm intent — the project's stance is that this is acceptable operational convenience.

## Style

- Bicep params: optional strings use `string = ''` checked with `!empty()`; required combinations validated via `var valid = condition ? fail('msg') : true` at top of `main.bicep` (see lines 38–43).
- Resource names: `resourceToken = toLower(uniqueString(resourceGroup().id, location))`.
- Never commit `.env`, `.env.secrets`, `.env.local`, or `tf/terraform.tfvars` (all git-ignored).
