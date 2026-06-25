# AI Gateway with JWT Auth + Access Contracts + Priority Routing

This deployment creates the unified **Azure API Management (APIM)** AI Gateway architecture. A single canonical inference policy, [`policy-per-model.xml`](../modules/apim/policy-per-model.xml), is shared by the passthrough `inference` API, spec-backed `inference-api-azure` API, conditional `openai-api-v1` API (Premium/StandardV2 SKUs), and static-discovery operations. Client applications are identified by JWT claims, matched to blob-backed **access contracts**, and subject to **per-model TPM quotas**, **monthly token budgets**, and **2-tier priority routing** (P1 → mixed PTU+PAYG pool with circuit breaker failover, P2 → PAYG-only with quota enforcement).

## Features

- **JWT Bearer Token Auth** — `validate-azure-ad-token` against Entra ID (no APIM subscription keys)
- **Single Policy Stack** — `policy-per-model.xml` is the canonical policy for all inference API surfaces and static discovery operations
- **Access Contracts** — Per-team configuration (models, TPM limits, PTU allocations, monthly budgets) stored in blob storage and loaded by the `caller-identity` fragment
- **2-Tier Priority Routing** — `per-model-routing` sends P1 Production to mixed PTU+PAYG pools and P2/other callers to PAYG-only pools
- **Circuit Breaker Failover** — PTU backends have circuit breaker rules; when tripped (429/503), APIM automatically routes to PAYG backends in the same pool
- **Per-Model TPM Quotas** — Hard 429 enforcement via `llm-token-limit` with custom `counter-key`
- **Monthly Token Budgets** — Native enforcement via `llm-token-limit` with `token-quota-period=Monthly` (conditional — see [Quota Compromise](#quota-compromise))
- **Automatic Entra ID App Registration** — Dynamic creation per contract via Microsoft Graph Bicep extension
- **Multi-Backend Routing** — One backend per `(instance, model, location)`, plus per-model mixed and PAYG-only pools with circuit breaker failover
- **Event Hub Notifications** — Quota-exceeded events for downstream processing
- **Azure Portal Dashboard** — KQL-based monitoring (token usage, rate limits, routing decisions)
- **Foundry Headers** — `x-foundry-agent-id`, `x-foundry-project-name`, `x-foundry-project-id` for Foundry agent tracing
- **Observability Headers** — Captured by `log-settings.bicep`, including `x-caller-*`, `x-backend-*`, `x-inference-failover`, quota/rate-limit, and Foundry project headers

## Architecture Overview

The gateway uses **APIM's native circuit breaker and priority-based backend pools** for PTU→PAYG failover. The same `policy-per-model.xml` and fragments handle JWT auth, contract resolution, quota checks, and routing on every inference API surface. For P1 (Production) callers, it routes to a **mixed pool** where PTU backends are at priority 1 and PAYG backends are at priority 2. When PTU backends return 429/503, the circuit breaker trips and APIM automatically fails over to PAYG backends. P2 (Standard) callers route directly to a PAYG-only pool to avoid consuming PTU capacity.

```
  Client App                        APIM Gateway (Circuit Breaker Pattern)
  (Entra ID)                       ┌──────────────────────────────────────────────────────────┐
       │                           │                                                          │
       │ 1. Get token              │   Inference API (external)                               │
       │    (MSAL → Entra ID)      │   ┌───────────────────────────────────────────────────┐  │
       │                           │   │ 1. validate-azure-ad-token                        │  │
       │ 2. Call API with          │   │ 2. Identity resolution (JWT claims → contract)    │  │
       │    Bearer token           │   │ 3. Per-model TPM check (llm-token-limit)          │  │
       ├──────────────────────────►│   │ 4. Monthly quota check (conditional)              │  │
       │                           │   │ 5. Route by priority:                             │  │
       │                           │   │    P1 → Mixed pool (PTU pri 1, PAYG pri 50/100)        │  │
       │                           │   │    P2 → PAYG-only pool                            │  │
       │                           │   └──────────────┬──────────────────┬─────────────────┘  │
       │                           └──────────────────┼──────────────────┼──────────────────────┘
                                                      │                  │
                                                      ▼                  ▼
                                           ┌───────────────────┐ ┌──────────────────┐
                                           │ {model}-pool      │ │ {model}-payg-pool│
                                           │  PTU (pri 1)      │ │  PAYG backends   │
                                           │  PAYG (pri 50/100)     │ │  (Standard only) │
                                           │  circuit breaker   │ └──────────────────┘
                                           └───────────────────┘
                                             │               │
                                      ┌──────┴──────┐ ┌─────┴──────┐
                                      │ Foundry PTU │ │Foundry PAYG│
                                      │ (dedicated) │ │(pay-per-use│
                                      └─────────────┘ └────────────┘

  Supporting Services: Log Analytics │ App Insights │ Event Hub │ Blob Storage (contracts) │ Dashboard
```

## Request Flow

```
Client → APIM Gateway
  1. JWT Validation     — Validate token against Entra ID (audience: https://cognitiveservices.azure.com)
  2. Identity Resolution — Extract azp/appid/xms_mirid/oid/sub claims → match to contract
  3. Contract Lookup     — `caller-identity` loads contracts JSON from blob (cached 5 min) → resolve team name, priority, model quotas
  4. Model Authorization — Check requested model is in contract's allow-list, extract TPM/ptuTpm
  5. Per-Model TPM       — llm-token-limit (counter-key = "caller:model", tokens-per-minute) → 429 if over
  6. Monthly Quota       — llm-token-limit (conditional — see Quota Compromise) → 429 if over
  7. Priority Routing    — `per-model-routing` chooses a backend pool based on priority tier:
       P1 (Production): Mixed pool `{model}-pool` (PTU pri 1, in-region PAYG pri 50, out-of-region PAYG pri 100)
       P2/other:        PAYG-only pool `{model}-payg-pool`, quota always enforced
```


## Unified Policy Stack

`policy-per-model.xml` is the single inference policy stack. It is applied to:

- the passthrough `inference` API (`/inference/openai/...` and `/inference/anthropic/...`)
- the spec-backed `inference-api-azure` API (`/azure/openai/...`)
- the conditional `openai-api-v1` API (`/openai/v1/...`, only on Premium/StandardV2-capable SKUs)
- static-discovery operations that return the deploy-time model catalog

Two fragments keep the policy reusable:

- `caller-identity` sets observability defaults in open mode. When `caller-identity-fragment.bicep` receives `contractsBlobUrl`, `{contracts-load-section}` injects JWT validation, blob lookup, identity matching, and per-model authorization. Without contracts, neutral defaults flow through and `<llm-token-limit>` blocks short-circuit because they are wrapped in `<choose when="model-tpm > 0">`.
- `per-model-routing` extracts the requested model and routes `priority == 1` callers to `{model}-pool` (mixed PTU+PAYG) and other callers to `{model}-payg-pool` (PAYG only). PAYG backends are region-aware: in-region priority 50, out-of-region priority 100.

## Priority Tiers

| Priority | Label | Routing | Quota Enforcement |
|----------|-------|---------|-------------------|
| **P1** | Production | Mixed pool (PTU pri 1, PAYG pri 50/100) — circuit breaker failover | Conditional (see [Quota Compromise](#quota-compromise)) |
| **P2** | Standard | PAYG only | Always enforced |

## Quota Compromise

Monthly quota enforcement interacts with PTU routing in a nuanced way:

| Scenario | Quota Enforced? | Rationale |
|----------|-----------------|-----------|
| **P1 with 100% PTU allocation** | ❌ No | PTU is dedicated capacity (paid whether used or not) — there's nothing to budget-cap. |
| **P1 with partial PTU** | ✅ Yes | The single quota counter captures both PTU and PAYG usage. The limit serves as a cap on total consumption, though it's not per-backend precise. |
| **P2 (Standard)** | ✅ Yes | All traffic is PAYG — always quota-enforced. |

> **Note on quota counting**: The monthly quota is counted **once** per request (in the Priority API's inbound section, before routing). It is not double-counted on retry. However, when PTU is hit, those tokens are effectively "free" (pre-paid), so the quota counter includes both PTU and PAYG tokens in a single total — it doesn't distinguish between the two backends.

> **Alternative approach**: An alternative architecture would return PTU 429/503 errors directly to the client (no automatic retry) and let clients specify their preferred backend via a header. This would enable separate per-LLM quotas for PTU and PAYG independently. The current design prioritizes transparent failover at the cost of a combined quota counter.

## JWT Audience: `https://cognitiveservices.azure.com`

The gateway validates tokens with audience `https://cognitiveservices.azure.com` — the standard Azure Cognitive Services audience. This is intentional:

- **Simpler for clients** — any Azure AI SDK or tool that already targets Cognitive Services can use the gateway with no token changes.
- **Still secure** — a Cognitive Services token alone grants **no access** to any Foundry instance. Access requires an RBAC role assignment on the specific resource. Only APIM's managed identity has `Cognitive Services User` on the backends; team apps do not.
- **Authorization via access contracts** — the gateway enforces per-team access through identity matching, model allow-lists, TPM limits, and monthly quotas — independent of the token audience.

> **Token generation**: use `https://cognitiveservices.azure.com/.default` as the MSAL scope.
> The `generate_token.py --from-azd` flag does this automatically.

## Access Contracts

Access contracts replace the earlier Gold/Silver/Bronze tier system. Each contract defines a team's identity, priority, allowed models with per-model TPM limits, and monthly token budget. Contracts are defined in `main.bicepparam` and compiled to blob storage at deploy time (cached 5 min in APIM). Runtime reads use `GET /ai-gateway/config.json`; updates use `POST /ai-gateway/config/update`.

### Contract Type

```
accessContractType:
  name: string               # Team name (counter-key for quotas)
  identities: [{              # JWT claim matchers (empty = auto-create Entra app)
    value: string             #   Claim value (prefix match)
    displayName: string       #   Human label
    claimName: string         #   "azp" | "appid" | "xms_mirid" | "oid" | "sub"
  }]
  priority: 1 | 2              # 1=Production (PTU+PAYG), 2=Standard (PAYG only)
  models: [{                  # Allow-list + quotas per model
    name: string              #   Model deployment name (e.g., "gpt-4.1-mini")
    tpm: int                  #   Hard TPM limit (429 enforcement)
    ptuTpm: int?              #   Soft PTU allocation (P1 only, overflow → PAYG)
  }]
  monthlyQuota: int           # Monthly token budget (hard 429 for non-P1)
  environment: string?        # Tag: "PROD" | "DEV" | "TEST"
```

### Example Contracts (from `main.bicepparam`)

| Team | Priority | Models | TPM | PTU TPM | Monthly Quota |
|------|----------|--------|-----|---------|---------------|
| Team Alpha | P1 (Production) | gpt-4.1-mini | 1,000 | 100 | 7,000 |
| | | gpt-oss-120b | 100 | — | |
| Team Beta | P2 (Standard) | gpt-4.1-mini | 400 | — | 3,000 |
| | | gpt-5.1-chat | 400 | — | |

P1 callers with 100% PTU allocation are **exempt from monthly quotas** — PTU is dedicated capacity (paid whether used or not), so there's nothing to budget-cap. P1 callers with partial PTU are still quota-enforced (see [Quota Compromise](#quota-compromise)).

## Entra ID App Registrations

The deployment dynamically creates Entra ID app registrations for contracts with empty `identities` arrays. This uses the [Microsoft Graph Bicep extension](https://learn.microsoft.com/en-us/graph/templates/bicep/quickstart-create-bicep-interactive-mode) (`extension microsoftGraphV1`) in `entra/entra-apps-dynamic.bicep`.

The deploying identity needs **`Application.ReadWrite.All`** permission. Client secrets are created post-deploy via `scripts/add_app_reg_secrets.sh` and stored in `azd env`.

Teams with pre-existing Entra apps or managed identities can bring their own identities by populating the `identities` array in their contract — no app registration is created for them.

## Backend Naming & Multi-Region Support

### Backend Naming Convention

Backends are created per `(instance, model, location)` triplet with names like `{instance}-{model-clean}-{location-clean}-backend`. Circuit breaker state is therefore per model, so one throttled model does not disable other models on the same Foundry instance. This ensures unique backend identity when multiple Foundry instances serve the same model in different Azure regions:

```
Topology: 2 paygo in eastus2 + 1 paygo in westus + 1 PTU in eastus

Backends created:
  ✓ foundry-paygo-a-gpt41mini-eastus2-backend       (PTU: false, Location: eastus2)
  ✓ foundry-paygo-b-gpt41mini-eastus2-backend       (PTU: false, Location: eastus2)
  ✓ foundry-paygo-c-gpt41mini-westus-backend        (PTU: false, Location: westus)
  ✓ foundry-ptu-gpt41mini-eastus-backend            (PTU: true,  Location: eastus)

Pools created (per-model only, not per-region):
  ✓ gpt41mini-pool        → mixed pool: PTU priority 1 + PAYG priority 50/100
  ✓ gpt41mini-payg-pool   → PAYG-only pool: priority 50 in-region, 100 out-of-region
```

**Pools remain model-scoped** — a mixed `{model}-pool` contains PTU plus PAYG backends when PTU exists, and `{model}-payg-pool` contains PAYG backends only. Circuit breakers on PTU backends handle automatic failover to PAYG without requiring region-based pool separation.

## ⚠️ Critical: Consistent Deployment Names

All Azure OpenAI / Foundry instances serving the same model **must** use the **same deployment name**, matching the `modelName` in the configuration. APIM backend pools forward the URL path unchanged — mismatched names cause intermittent 404s.

```
✅  PTU instance:    deployment "gpt-4.1-mini"
✅  PAYG instance:   deployment "gpt-4.1-mini"
❌  PTU instance:    deployment "gpt-4.1-mini-ptu"   ← BREAKS routing (404)
```

See [Section 5 of PTU Design Risks](docs/ptu-design-risks.md#5-deployment-naming-convention--hard-requirement) for the full rationale and setup checklist.

## Known Limitations

- **`x-quota-remaining-tokens` is an unreliable estimate on APIM StandardV2.** The value bounces erratically between requests due to platform-level counter behavior, not policy logic. The internal counter tracks correctly — enforcement (403) fires at the right time, but the reported remaining value is noisy. Per [Microsoft docs](https://learn.microsoft.com/en-us/azure/api-management/azure-openai-token-limit-policy): *"The value is an estimate for informational purposes."*

- **Combined PTU + PAYG quota counter.** For P1 callers with partial PTU, the monthly quota counts total tokens across both backends. Since PTU tokens are pre-paid, this means the quota limit is a cap on total consumption rather than a precise measure of PAYG cost. See [Quota Compromise](#quota-compromise).

## Config Endpoints

The `config-viewer-api` exposes the runtime contract config endpoints:

| Endpoint | Method | Description |
|---|---|---|
| `/ai-gateway/config` | GET | Styled HTML dashboard showing all team contracts |
| `/ai-gateway/config.json` | GET | Raw JSON of all access contracts |
| `/ai-gateway/config/update` | POST | Writes updated contract JSON back to the contracts blob |

```bash
# View contracts as JSON
curl -s https://<apim-gateway>/ai-gateway/config.json | jq .

# Update contracts in blob
curl -X POST https://<apim-gateway>/ai-gateway/config/update \
  -H "Content-Type: application/json" \
  --data @contracts.json
```

> **⚠️ No authentication** — These endpoints are intentionally public for operational convenience. They expose team names, Entra app IDs, priority tiers, and quota limits. No secrets are exposed (app IDs are not secret). If your security posture requires restricting access, add `subscriptionRequired: true` to the `config-viewer-api` resource or add an internal key check to the policy.

## Deploy

### Prerequisites

- **Azure subscription** with Contributor access
- **Application.ReadWrite.All** permission for Entra ID app registrations
- Azure OpenAI / Foundry instances (PTU and/or PAYG) with model deployments

### Deployment Options

| Method | Directory | Tooling | Notes |
|--------|-----------|---------|-------|
| **Bicep** (primary) | Root | `azd up` | Main deployment — uses `azd` and `.env` for configuration |
| **Terraform** | `tf/` | `terraform apply` | Legacy/experimental path; verify it is in sync with the blob-backed Bicep policy stack before use |

### Quick Start (Bicep)

```bash
cd options-infra/ai-gateway-quota

# Set Foundry instance details (or use azd env set)
export OPENAI_API_BASE="https://your-openai.openai.azure.com/"
export OPENAI_RESOURCE_ID="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>"

azd up
```

The deployment:
1. Creates Entra ID app registrations dynamically per contract (empty `identities`)
2. Runs `options-infra/scripts/preprovision-list-foundry-models.sh` before each `azd up` to discover Foundry instances/deployments and write `FOUNDRY_INSTANCES_JSON`; `main.bicepparam` reads it via `json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))`
3. Deploys APIM with the single `policy-per-model.xml` stack, fragments, backend pools, blob storage for contracts, and monitoring
4. Post-provision hook creates client secrets and stores them in `azd env`

## Test / Generate Token / Simulate Traffic

The live pytest suite is in `tests/` and covers chat, TTS, Whisper, quota, contract, and failover behavior.

```bash
cd options-infra/ai-gateway-quota/tests
uv sync
uv run pytest -v
```

### Generate a token

```bash
python scripts/generate_token.py --from-azd alpha --decode
```

Or specify credentials explicitly:

```bash
python scripts/generate_token.py \
    --tenant-id <TENANT_ID> \
    --client-id <CLIENT_ID> \
    --client-secret <CLIENT_SECRET> \
    --decode
```

### Call the gateway

```bash
TOKEN=$(python scripts/generate_token.py --from-azd alpha)

curl -s https://<apim-gateway>/inference/openai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-02-01 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

### Simulate multi-team traffic

```bash
python scripts/simulate_traffic.py --requests-per-team 10 --model gpt-4.1-mini
```

## Monitoring

### Token Usage by Caller

```kql
ApiManagementGatewayLogs
| where ApiId == "inference-api"
| extend callerName = tostring(parse_json(RequestHeaders)["x-caller-name"])
| extend callerPriority = tostring(parse_json(RequestHeaders)["x-caller-priority"])
| summarize RequestCount=count(), AvgLatency=avg(TotalTime) by callerName, callerPriority, ResponseCode
| order by callerName asc
```

### Rate Limit Events

```kql
ApiManagementGatewayLogs
| where ResponseCode == 429
| extend callerName = tostring(parse_json(RequestHeaders)["x-caller-name"])
| extend backendPool = tostring(parse_json(ResponseHeaders)["x-backend-pool"])
| summarize RateLimitedCount=count() by callerName, backendPool, bin(Timestamp, 1m)
| order by Timestamp desc
```

### Response Headers

Every successful response includes observability headers captured by `log-settings.bicep`:

| Header | Description |
|--------|-------------|
| `x-caller-name`, `x-caller-id`, `x-caller-priority`, `x-caller-identity`, `x-caller-foundry`, `x-caller-project` | Caller/contract identity and priority |
| `x-backend-id`, `x-backend-pool`, `x-backend-retry-count`, `x-backend-attempt-trail`, `x-inference-failover` | Backend selection and failover trail |
| `x-requested-model`, `x-ptu-limit` | Requested model and contract PTU allocation |
| `x-tokens-consumed`, `x-ratelimit-remaining-tokens`, `x-ratelimit-limit-tokens` | Per-minute token-limit telemetry |
| `x-quota-tokens-consumed`, `x-quota-remaining-tokens`, `x-quota-limit-tokens` | Monthly quota telemetry |
| `x-foundry-agent-id`, `x-foundry-project-name`, `x-foundry-project-id` | Foundry agent/project tracing |

## Deployment Topologies

| Topology | APIM SKU | HA/DR | Fully Private | Best For |
|----------|----------|-------|---------------|----------|
| **A: Single-Region** | Standard v2 | ❌ APIM is SPOF | ✅ Internal VNet (Premium v2) | MVP, cost-sensitive |
| **B1: APIM Multi-Region** | Premium (classic or v2) | ✅ Auto failover | ✅ Fully private | Production, private networks |
| **B2: Front Door + APIM** | Standard v2 | ✅ Global failover | ⚠️ Client→AFD public | Public-facing APIs |
| **B3: App GW per Region** | Any private-capable | ✅ DNS failover | ✅ Fully private | Zero public exposure |

See [docs/architecture-plan.md](docs/architecture-plan.md) for detailed topology diagrams, SKU notes, and cost analysis.

## Documentation

- **[Architecture Plan](docs/architecture-plan.md)** — Alternative approaches evaluated, comparison table, FinOps reference
- **[PTU Design Risks](docs/ptu-design-risks.md)** — Deployment naming requirements, multi-region topology, resolved design risks
- **[Citadel-Inspired Implementation](docs/jwt-citadel-implementation.md)** — How this project adapts the Citadel access contracts pattern
- **[TPM Calculation](docs/tpm-calculation.md)** — How tokens-per-minute limits are calculated and enforced
- **[PTU Deployment Sizing](docs/ptu-deployment-sizing.md)** — Guidance for sizing PTU deployments and capacity planning

## Research Sources

| Source | Link |
|--------|------|
| Citadel (AI Hub Gateway) | [`Azure-Samples/ai-hub-gateway-solution-accelerator`](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) (citadel-v1 branch) |
| AI-Gateway | `Azure-Samples/AI-Gateway` |
| GenAI Playbook | [MS Learn: Maximize PTU Utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization) |
| ai-gw-v2 | [`Heenanl/ai-gw-v2`](https://github.com/Heenanl/ai-gw-v2) (usecaseonboard / jwtauth branches) |
| SimpleL7Proxy | [`microsoft/SimpleL7Proxy`](https://github.com/microsoft/SimpleL7Proxy) |
| ai-policy-engine | [`Azure-Samples/ai-policy-engine`](https://github.com/Azure-Samples/ai-policy-engine) — ASP.NET 10 + APIM reference for AI governance with per-tenant billing (Redis + CosmosDB), monthly quotas, RPM/TPM limits, and a React dashboard. Heavier infrastructure than this project but stronger on chargeback/billing. No explicit PTU/PAYG priority routing. |
