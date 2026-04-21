# AI Gateway with JWT Auth + Access Contracts + Priority Routing

This deployment creates an **Azure API Management (APIM)** AI Gateway with **JWT Bearer Token authentication** via Entra ID. Client applications are identified by JWT claims, matched to **access contracts** stored in blob storage, and subject to **per-model TPM quotas**, **monthly token budgets**, and **2-tier priority routing** (P1 → mixed PTU+PAYG pool with circuit breaker failover, P2 → PAYG-only with quota enforcement).

## Features

- **JWT Bearer Token Auth** — `validate-azure-ad-token` against Entra ID (no APIM subscription keys)
- **Access Contracts** — Per-team configuration (models, TPM limits, PTU allocations, monthly budgets) stored in blob storage (Bicep) or APIM named values (Terraform), cached 5 min
- **2-Tier Priority Routing** — P1 Production (mixed PTU+PAYG pool with circuit breaker), P2 Standard (PAYG only, quota enforced)
- **Circuit Breaker Failover** — PTU backends have circuit breaker rules; when tripped (429/503), APIM automatically routes to PAYG backends in the same pool
- **Per-Model TPM Quotas** — Hard 429 enforcement via `llm-token-limit` with custom `counter-key`
- **Monthly Token Budgets** — Native enforcement via `llm-token-limit` with `token-quota-period=Monthly` (conditional — see [Quota Compromise](#quota-compromise))
- **Automatic Entra ID App Registration** — Dynamic creation per contract via Microsoft Graph Bicep extension
- **Multi-Backend Routing** — Per-model mixed (PTU+PAYG) and PAYG-only pools with circuit breaker failover
- **Event Hub Notifications** — Quota-exceeded events for downstream processing
- **Azure Portal Dashboard** — KQL-based monitoring (token usage, rate limits, routing decisions)
- **Foundry Headers** — `x-foundry-agent-id`, `x-foundry-project-name`, `x-foundry-project-id` for Foundry agent tracing
- **Observability Headers** — `x-caller-name`, `x-backend-pool`, `x-backend-type`, `x-backend-id`, etc.

## Architecture Overview

The gateway uses **APIM's native circuit breaker and priority-based backend pools** for PTU→PAYG failover. The Inference API (external-facing) handles JWT auth, contract resolution, and quota checks. For P1 (Production) callers, it routes to a **mixed pool** where PTU backends are at priority 1 and PAYG backends are at priority 2. When PTU backends return 429/503, the circuit breaker trips and APIM automatically fails over to PAYG backends. P2 (Standard) callers route directly to a PAYG-only pool to avoid consuming PTU capacity.

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
       │                           │   │    P1 → Mixed pool (PTU pri 1, PAYG pri 2)        │  │
       │                           │   │    P2 → PAYG-only pool                            │  │
       │                           │   └──────────────┬──────────────────┬─────────────────┘  │
       │                           └──────────────────┼──────────────────┼──────────────────────┘
                                                      │                  │
                                                      ▼                  ▼
                                           ┌───────────────────┐ ┌──────────────────┐
                                           │ {model}-pool      │ │ {model}-payg-pool│
                                           │  PTU (pri 1)      │ │  PAYG backends   │
                                           │  PAYG (pri 2)     │ │  (Standard only) │
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
  3. Contract Lookup     — Load contracts JSON from blob (cached 5 min) → resolve team name, priority, model quotas
  4. Model Authorization — Check requested model is in contract's allow-list, extract TPM/ptuTpm
  5. Per-Model TPM       — llm-token-limit (counter-key = "caller:model", tokens-per-minute) → 429 if over
  6. Monthly Quota       — llm-token-limit (conditional — see Quota Compromise) → 429 if over
  7. Priority Routing    — Route to backend pool based on priority tier:
       P1 (Production): Mixed pool (PTU pri 1, PAYG pri 2) — circuit breaker handles failover
       P2 (Standard):   PAYG-only pool, quota always enforced
```

## Priority Tiers

| Priority | Label | Routing | Quota Enforcement |
|----------|-------|---------|-------------------|
| **P1** | Production | Mixed pool (PTU pri 1, PAYG pri 2) — circuit breaker failover | Conditional (see [Quota Compromise](#quota-compromise)) |
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

Access contracts replace the earlier Gold/Silver/Bronze tier system. Each contract defines a team's identity, priority, allowed models with per-model TPM limits, and monthly token budget. Contracts are defined in `main.bicepparam` and compiled to blob storage at deploy time (cached 5 min in APIM).

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

The `config-viewer-api` exposes three **publicly accessible** endpoints (no authentication required):

| Endpoint | Method | Description |
|---|---|---|
| `/gateway/config` | GET | Styled HTML dashboard showing all team contracts |
| `/gateway/config.json` | GET | Raw JSON of all access contracts |
| `/gateway/config/refresh` | POST | Clears blob cache (blob mode) or no-op (named value mode) |

```bash
# View contracts as JSON
curl -s https://<apim-gateway>/gateway/config.json | jq .

# View HTML dashboard in browser
open https://<apim-gateway>/gateway/config
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
| **Terraform** | `tf/` | `terraform apply` | Shares policy XMLs from `modules/apim/advanced/`; uses APIM named values instead of blob storage for contracts |

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
2. Deploys APIM with priority routing policy, backend pools, blob storage for contracts, and monitoring
3. Post-provision hook creates client secrets and stores them in `azd env`

## Generate Token / Simulate Traffic

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
| extend backendType = tostring(parse_json(ResponseHeaders)["x-backend-type"])
| summarize RateLimitedCount=count() by callerName, backendType, bin(Timestamp, 1m)
| order by Timestamp desc
```

### Response Headers

Every successful response includes observability headers:

| Header | Description |
|--------|-------------|
| `x-caller-name` | Contract name the caller was matched to |
| `x-caller-priority` | Priority label (`production` / `standard`) |
| `x-backend-pool` | Which backend pool served the request (e.g., `gpt41-pool`, `gpt41-payg-pool`) |
| `x-backend-type` | Backend type derived from `context.Backend.Id` (`ptu` or `payg`) |
| `x-backend-id` | Specific backend entity that served the request (from `context.Backend.Id`) |
| `x-route-target` | Routing decision (`mixed` or `payg`) |
| `x-ptu-limit` | PTU TPM allocation for this model from the contract |
| `x-quota-remaining-tokens` | Remaining tokens in the monthly quota (estimate — see [Known Limitations](#known-limitations)) |
| `x-ratelimit-remaining-tokens` | Remaining tokens in the current per-minute window |
| `x-foundry-agent-id` | Foundry agent ID (from `x-ms-foundry-agent-id` request header) |
| `x-foundry-project-name` | Foundry project name (from `openai-project` request header) |
| `x-foundry-project-id` | Foundry project ID (from `x-ms-foundry-project-id` request header) |

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
