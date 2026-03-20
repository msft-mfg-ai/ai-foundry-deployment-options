# AI Agent Reference — AI Gateway Quota (JWT Citadel with Priority Routing)

> Context document for AI coding agents working on the `ai-gateway-quota` deployment option.
> This file describes the architecture, conventions, file layout, common tasks, and critical constraints
> so that agents can make correct, safe changes without full codebase exploration.

---

## What This Project Does

**ai-gateway-quota** deploys an Azure API Management (APIM) gateway in front of multiple Azure OpenAI / AI Foundry instances. It provides:

- **JWT Bearer Token authentication** via Entra ID (no APIM subscription keys)
- **Per-team access contracts** with 3-tier priority routing (P1 → PTU-first, P2 → Standard, P3 → Economy/PAYG-only)
- **Per-model TPM quotas** (hard 429 limits) and **monthly token budgets** (cost caps)
- **Automatic Entra ID app registration** creation for teams (via Microsoft Graph Bicep extension)
- **Multi-backend routing** across PTU and PAYG Foundry instances with circuit breaker failover
- **Event Hub notifications** for quota-exceeded events
- **Azure Portal dashboard** with KQL-based monitoring

---

## Directory Structure

```
ai-gateway-quota/
├── main.bicep                     # Orchestrator — wires all modules together
├── main.bicepparam                # Parameters: foundry instances + access contracts
├── azure.yaml                     # Azure Developer CLI config + pre/post hooks
├── README.md                      # User-facing documentation
├── TODO.md                        # Feature roadmap
├── AGENTS.md                      # This file
│
├── entra/
│   ├── entra-apps-dynamic.bicep   # Creates Entra ID apps dynamically per contract
│   └── entra-apps.bicep           # Legacy static version (3 teams hardcoded)
│
├── types/
│   └── gateway-types.bicep        # User-defined types (foundryInstanceType, accessContractType, etc.)
│                                  #   NOTE: main.bicep imports types from modules/apim/advanced/types.bicep
│                                  #   This local file is kept as a mirror/reference.
│
├── dashboard/
│   ├── dashboard.bicep            # Azure Portal dashboard (KQL queries for token usage)
│   └── dashboard.json             # Compiled ARM template version
│
├── docs/
│   ├── README.md                  # Architecture quick-start
│   ├── architecture-plan.md       # 5 deployment topologies, risk analysis
│   ├── jwt-citadel-implementation.md  # Request flow, identity resolution, caching
│   └── ptu-design-risks.md        # Deployment naming, race conditions, capacity
│
├── scripts/
│   ├── generate_token.py          # MSAL token generation (--from-azd flag)
│   ├── simulate_traffic.py        # Multi-team traffic simulation
│   ├── add_app_reg_secrets.sh     # Post-deploy: create client secrets → azd env
│   ├── add_app_reg_secrets.ps1    # Windows version
│   ├── setup_entra_apps.sh        # Alternative manual Entra setup
│   ├── seed_quota.sh              # Dev seed data
│   └── pyproject.toml             # Python deps (msal, PyJWT, requests)
│
├── tests/
│   └── test_priority_gateway.ipynb  # End-to-end Jupyter notebook tests
│
├── policy.local/                  # Local APIM policy overrides (git-ignored)
├── main_old.bicep                 # Previous version (single backend, no priority routing)
├── main_old.bicepparam            # Previous parameters
└── old_policy_quota.xml           # Legacy APIM policy
```

---

## Key Shared Modules (in `options-infra/modules/`)

The main.bicep file references these shared modules. **Do not duplicate — reuse them.**

| Module | Path | Purpose |
|--------|------|---------|
| **AI Gateway Advanced** | `apim/ai-gateway-advanced.bicep` | Main APIM orchestrator (deploys APIM + policy + backends + storage) |
| **Multi-Foundry Backends** | `apim/advanced/multi-foundry-backends.bicep` | Per-model backend pools (PTU + PAYG) |
| **Contract Storage** | `apim/advanced/contract-storage.bicep` | Blob storage for access contract JSON |
| **Priority Routing Policy** | `apim/advanced/policy-priority.xml` | Core APIM policy (340 lines — JWT, quotas, routing) |
| **Identity Fragment** | `apim/advanced/fragment-identity.xml` | Shared policy fragment (JWT validation + identity resolution) |
| **PTU Gate Policy** | `apim/advanced/policy-ptu-gate.xml` | Loopback API for partial-PTU token counting |
| **Config Viewer Policy** | `apim/advanced/policy-config-viewer.xml` | Debug endpoint to view resolved contracts |
| **Token Estimation** | `apim/advanced/token-estimation-{inbound,outbound}.xml` | Token count estimation fragments |
| **Types** | `apim/advanced/types.bicep` | Canonical type definitions (imported by main.bicep) |
| **APIM v2** | `apim/v2/apim.bicep` | APIM service instance (Standard v2) |
| **Inference API** | `apim/v2/inference-api.bicep` | /inference/openai API definition |
| **Log Analytics** | `monitor/loganalytics.bicep` | Log Analytics + App Insights |
| **Event Hub** | `eventhub/eventhub.bicep` | Event Hub namespace + hub |
| **Role Assignments** | `iam/role-assignment-cognitiveServices.bicep` | Cognitive Services User role (cross-RG) |

---

## Architecture: Request Flow (7 Steps)

```
Client → APIM Gateway
  1. JWT Validation     — Validate token against Entra ID (audience: https://cognitiveservices.azure.com)
  2. Identity Resolution — Extract azp/appid/xms_mirid/oid/sub claims → match to contract
  3. Contract Lookup     — Load contracts JSON from blob (cached 5 min) → resolve team name, priority, model quotas
  4. Model Authorization — Check requested model is in contract's allow-list, extract TPM/ptuTpm
  5. Per-Model TPM       — llm-token-limit (counter-key = "caller:model", tokens-per-minute)  → 429 if over
  6. Monthly Quota       — llm-token-limit (counter-key = "caller", token-quota-period = Monthly) → 429 if over (non-P1 only)
  7. Priority Routing    — Route to PTU or PAYG pool based on priority tier:
       P1: Always PTU first, failover to PAYG on 429
       P2: PTU when utilization < 50%, otherwise PAYG
       P3: Always PAYG
```

### JWT Audience

The gateway uses `https://cognitiveservices.azure.com` as the token audience — **not** a custom gateway app ID. This is safe because:

- A Cognitive Services-scoped token alone grants **no access** to any Foundry instance without an RBAC role assignment on the resource.
- Only APIM's managed identity has `Cognitive Services User` on the backends; team apps do not.
- Authorization is enforced by access contracts (identity matching, model allow-lists, quotas), not the token audience.
- Clients can reuse standard Azure AI SDK tokens without reconfiguration.

**Token scope for MSAL**: `https://cognitiveservices.azure.com/.default`

---

## Type System

Types are defined in `modules/apim/advanced/types.bicep` (canonical) and mirrored in `types/gateway-types.bicep`.

### `foundryInstanceType`
```
name: string               # Friendly name (e.g., "foundry-eastus2-ptu")
resourceId: string          # Full Azure resource ID
endpoint: string            # e.g., "https://my-foundry.openai.azure.com/"
location: string            # Azure region
isPtu: bool                 # true = PTU-only instance, false = PAYG-only
deployments: [{             # Model deployments on this instance
  modelName: string         #   MUST equal the Azure OpenAI deployment name
  ptuCapacityTpm: int?      #   Required on PTU instances
}]
priority: int?              # Load-balancing priority (lower = preferred)
weight: int?                # Load-balancing weight within same priority
```

### `accessContractType`
```
name: string                # Team name (also the counter-key for quotas)
identities: [{              # JWT claim matchers (empty = auto-create Entra app)
  value: string             #   Claim value (prefix match)
  displayName: string       #   Human label
  claimName: string         #   "azp" | "appid" | "xms_mirid" | "oid" | "sub"
}]
priority: 1 | 2 | 3         # 1=Production, 2=Standard, 3=Economy
models: [{                  # Allow-list + quotas per model
  name: string              #   Model name (e.g., "gpt-4.1-mini")
  tpm: int                  #   Hard TPM limit (429 enforcement)
  ptuTpm: int?              #   Soft PTU allocation (overflow → PAYG)
}]
monthlyQuota: int           # Monthly token budget (hard 429 for non-P1)
environment: string?        # Tag: "PROD" | "DEV" | "TEST"
```

---

## Critical Constraints & Gotchas

### 1. Deployment Naming (HARD REQUIREMENT)
All Foundry instances serving the same model **MUST use identical deployment names** matching the model name:
```
✅ PTU instance:  deployment name = "gpt-4.1-mini"
✅ PAYG instance: deployment name = "gpt-4.1-mini"
❌ PTU instance:  deployment name = "gpt-4.1-mini-ptu"   ← BREAKS routing (404)
```
**Why:** APIM backend pools forward the URL path `/openai/deployments/{name}/...` unchanged. Mismatched names cause intermittent 404s.

### 2. No Secrets in Bicep Outputs
The `bicepconfig.json` enforces `outputs-should-not-contain-secrets: error`. Never output secrets, keys, or connection strings from Bicep.

### 3. PTU Instances Must Be Pure
Each `foundryInstance` is either `isPtu: true` (all deployments are PTU) or `isPtu: false` (all PAYG). **Do not mix** PTU and PAYG deployments on the same instance.

### 4. Monthly Quota Exemption for P1
Priority 1 (Production) callers are **exempt from monthly quotas** because PTU is pre-paid. PAYG overflow from P1 is expected and not budget-capped.

### 5. Contract Cache TTL
Access contracts loaded from blob storage are **cached 5 minutes** in APIM. Changes to contracts take up to 5 min to propagate.

### 6. Cross-Resource-Group Role Assignments
APIM needs `Cognitive Services User` role on each Foundry instance. These are deployed with `@batchSize(1)` (serial) because cross-RG deployments can race.

### 7. Microsoft Graph Extension
The `entra-apps-dynamic.bicep` module uses `extension microsoftGraphV1`. The deploying identity needs `Application.ReadWrite.All` permission (not just `OwnedBy`).

### 8. `remainingTokens` Variable Type
The `azure-openai-token-limit` / `llm-token-limit` policy stores `remaining-tokens-variable-name` as `System.Int32`, **not String**. Use `.ToString()` to read it in headers or expressions — `GetValueOrDefault<string>()` will throw.

### 9. Local Parameter Files
`*.local.bicepparam` and `policy.local/` are git-ignored. Copy from `main.bicepparam` for local use. **Never commit local param files.**

### 10. Environment Variables in Parameters
`main.bicepparam` uses `readEnvironmentVariable()` for Foundry resource IDs and endpoints. These are set via `azd env set` or `.env` files. Default values are placeholder UUIDs — they must be overridden for real deployments.

---

## Common Tasks

### Validate Bicep (CI does this automatically)
```bash
# From repo root
bicep build options-infra/ai-gateway-quota/main.bicep
bicep lint options-infra/ai-gateway-quota/main.bicep
```

### Deploy
```bash
cd options-infra/ai-gateway-quota
azd up
```

### Generate a Bearer Token
```bash
cd options-infra/ai-gateway-quota
python scripts/generate_token.py --from-azd alpha --decode
```

### Simulate Traffic
```bash
cd options-infra/ai-gateway-quota
python scripts/simulate_traffic.py --requests-per-team 10
```

### Debug APIM Policy Errors
```kql
ApiManagementGatewayLogs
| where ResponseCode == 500
| project TimeGenerated, LastErrorMessage, LastErrorReason, LastErrorSection, LastErrorSource
| order by TimeGenerated desc
```

### Check Token Consumption
```kql
ApiManagementGatewayLlmLog
| summarize TotalTokens = sum(TotalTokens) by CallerIpAddress, bin(TimeGenerated, 1h)
| order by TimeGenerated desc
```

---

## APIM Policy Conventions

When editing XML policy files in `modules/apim/advanced/`:

- **Fragments** (`fragment-*.xml`) are reusable pieces included via `<include-fragment>` — they do NOT have `<policies>` root.
- **Full policies** (`policy-*.xml`) have the `<policies><inbound>...<backend>...<outbound>...<on-error>...</policies>` structure.
- Use `<set-variable>` for intermediate values; reference with `context.Variables.GetValueOrDefault<T>("name")`.
- Use `<cache-lookup-value>` / `<cache-store-value>` for cross-request state (PTU utilization tracking).
- **Counter keys** for `llm-token-limit`:
  - Per-model TPM: `"{callerName}:{modelName}"` (scoped to team + model)
  - Monthly quota: `"{callerName}"` (shared across all models for the team)
- **Response headers** are set in `<outbound>` for observability (17 `x-*` headers).

---

## Bicep Conventions

- **`resourceToken`** = `toLower(uniqueString(resourceGroup().id, location))` — used for unique resource names.
- **Parameters**: `location` defaults to `resourceGroup().location`.
- **Tags**: Always include `created-by`, `hidden-title`, and `SecurityControl: 'Ignore'`.
- **Module references**: Use relative paths from the consuming file (e.g., `'../modules/apim/ai-gateway-advanced.bicep'`).
- **Type imports**: `import { typeName } from '../modules/apim/advanced/types.bicep'`.
- **Validation**: Use `empty(param) ? fail('message') : true` pattern for required arrays.
- **Linter**: `bicepconfig.json` at `options-infra/` root applies to all templates. 4 rules are errors, ~30 are warnings, 2 are off.

---

## Deployment Hooks (azure.yaml)

| Hook | Timing | Action |
|------|--------|--------|
| `preprovision` | Before deployment | Sets `CURRENT_USER_OBJECT_ID` from signed-in Azure CLI user |
| `postprovision` | After deployment | Runs `add_app_reg_secrets.sh/.ps1` to create client secrets and store in azd env |

---

## Testing Strategy

1. **Bicep validation** — `bicep build` + `bicep lint` (CI workflow: `bicep-ai-gateway-quota.yml`)
2. **Token generation** — `scripts/generate_token.py` produces MSAL tokens for each team
3. **Traffic simulation** — `scripts/simulate_traffic.py` sends concurrent requests across teams
4. **Jupyter notebook** — `tests/test_priority_gateway.ipynb` runs end-to-end scenarios:
   - Token generation + API calls per team
   - Rate limit (429) verification
   - Monthly quota overflow testing
   - Response header validation
4. **KQL monitoring** — Dashboard queries verify token consumption, error rates, routing decisions

---

## Feature Roadmap (from TODO.md)

| Priority | Feature | Notes |
|----------|---------|-------|
| High | Scale to 100+ clients | Named Value limits, external storage alternatives |
| High | Per-consumer self-service config | APIM ops team manages contracts |
| High | Virtual PTU quotas | Soft limits with PAYG overflow |
| Medium | Monthly quota notifications | 80%/90% threshold alerts (email, Teams, Azure Monitor) |
| — | FinOps chargeback | Cost per team, PTU utilization reporting |

---

## Relationship to Other Deployment Options

This is one of 8+ AI Gateway variants in the repo:

| Option | Difference from `ai-gateway-quota` |
|--------|------------------------------------|
| `ai-gateway` | Basic APIM v2, no quotas or priority routing |
| `ai-gateway-basic` | Minimal Foundry + APIM, no JWT |
| `ai-gateway-premium` | APIM Premium with VNet injection |
| `ai-gateway-internal` | Internal APIM proxying to external OpenAI |
| `ai-gateway-pe` | APIM Standard v2 with private endpoints |
| `ai-gateway-openrouter` | OpenRouter backend instead of Foundry |
| `ai-gateway-litellm` | LiteLLM on ACA + PostgreSQL |

All share modules from `options-infra/modules/`. Changes to shared modules trigger CI for **all** gateway variants.
