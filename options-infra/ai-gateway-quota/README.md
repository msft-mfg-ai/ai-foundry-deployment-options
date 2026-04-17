# AI Gateway with JWT Auth + Access Contracts + Priority Routing

This deployment creates an **Azure API Management (APIM)** AI Gateway with **JWT Bearer Token authentication** via Entra ID. Client applications are identified by JWT claims, matched to **access contracts** stored in blob storage, and subject to **per-model TPM quotas**, **monthly token budgets**, and **3-tier priority routing** (P1 → PTU-first with PAYG failover, P2/P3 → PAYG-only).

## Features

- **JWT Bearer Token Auth** — `validate-azure-ad-token` against Entra ID (no APIM subscription keys)
- **Access Contracts** — Per-team configuration (models, TPM limits, PTU allocations, monthly budgets) stored in blob storage and cached 5 min
- **3-Tier Priority Routing** — P1 → PTU first (PAYG failover on 429), P2/P3 → PAYG only
- **Per-Model TPM Quotas** — Hard 429 enforcement via `llm-token-limit` with custom `counter-key`
- **Monthly Token Budgets** — Native enforcement via `llm-token-limit` with `token-quota-period=Monthly` (non-P1 only)
- **Two-API Loopback Architecture** — Priority API (external) + PTU Gate API (internal) for atomic PTU capacity enforcement
- **Automatic Entra ID App Registration** — Dynamic creation per contract via Microsoft Graph Bicep extension
- **Multi-Backend Routing** — Per-model PTU and PAYG pools with circuit breaker failover
- **Event Hub Notifications** — Quota-exceeded events for downstream processing
- **Azure Portal Dashboard** — KQL-based monitoring (token usage, rate limits, routing decisions)
- **17 Observability Headers** — `x-caller-name`, `x-route-target`, `x-backend-type`, `x-ptu-utilization`, etc.

## Architecture Overview

The gateway uses a **loopback pattern inspired by [Citadel](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) access contracts** for atomic PTU counting. The Priority API (external-facing) handles JWT auth, contract resolution, and quota checks. For P1 callers it issues an internal loopback call to the PTU Gate API, which atomically checks PTU capacity via `llm-token-limit` and forwards to the PTU backend pool. If PTU returns 429 or 503, the Priority API retries to the PAYG pool. An **internal API key** protects all loopback APIs from external access.

```
  Client App                        APIM Gateway (Two-API Loopback)
  (Entra ID)                       ┌─────────────────────────────────────────────────────────┐
       │                           │                                                         │
       │ 1. Get token              │   Priority API (external)                               │
       │    (MSAL → Entra ID)      │   ┌──────────────────────────────────────────────────┐  │
       │                           │   │ 1. validate-azure-ad-token                       │  │
       │ 2. Call API with          │   │ 2. Identity resolution (JWT claims → contract)   │  │
       │    Bearer token           │   │ 3. Per-model TPM check (llm-token-limit)         │  │
       ├──────────────────────────►│   │ 4. Monthly quota check (non-P1 only)             │  │
       │                           │   │ 5. Route by priority:                            │  │
       │                           │   │    P1 → PTU Gate (loopback) → PAYG fallback      │  │
       │                           │   │    P2/P3 → PAYG pool directly                    │  │
       │                           │   └──────────────┬──────────────────┬────────────────┘  │
       │                           │                  │                  │                    │
       │                           │   PTU Gate API   │                  │                    │
       │                           │   (internal)     │                  │                    │
       │                           │   ┌──────────────▼───────────┐     │                    │
       │                           │   │ llm-token-limit (PTU     │     │                    │
       │                           │   │ capacity per model)      │     │                    │
       │                           │   │ → forward to PTU pool    │     │                    │
       │                           │   │ → 429 if PTU exhausted   │     │                    │
       │                           │   └──────────────┬───────────┘     │                    │
       │                           └──────────────────┼─────────────────┼────────────────────┘
                                                      │                 │
                                                      ▼                 ▼
                                           ┌──────────────────┐ ┌──────────────────┐
                                           │ {model}-ptu-pool │ │ {model}-payg-pool│
                                           │  PTU backends    │ │  PAYG backends   │
                                           │  (circuit break) │ │  (circuit break) │
                                           └──────────────────┘ └──────────────────┘
                                                      │                 │
                                              ┌───────┴───────┐ ┌──────┴───────┐
                                              │ Foundry PTU   │ │ Foundry PAYG │
                                              │ (pre-paid)    │ │ (pay-per-use)│
                                              └───────────────┘ └──────────────┘

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
  6. Monthly Quota       — llm-token-limit (counter-key = "caller", token-quota-period = Monthly) → 429 if over (non-P1 only)
  7. Priority Routing    — Route to PTU or PAYG pool based on priority tier:
       P1: Always PTU first (via PTU Gate loopback), failover to PAYG on 429
       P2/P3: Always PAYG pool directly
```

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
  priority: 1 | 2 | 3         # 1=Production (PTU), 2/3=PAYG only
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
| Team Beta | P2 (Standard) | gpt-4.1-mini | 400 | 200 | 3,000 |
| | | gpt-5.1-chat | 400 | — | |
| Team Gamma | P3 (Economy) | gpt-4.1-mini | 300 | — | 1,000 |
| | | gpt-4.1 | 100 | — | |

P1 callers are **exempt from monthly quotas** — PTU is pre-paid, so PAYG overflow is expected and not budget-capped.

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

## Deploy

### Prerequisites

- **Azure subscription** with Contributor access
- **Application.ReadWrite.All** permission for Entra ID app registrations
- Azure OpenAI / Foundry instances (PTU and/or PAYG) with model deployments

### Quick Start

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
| `x-caller-priority` | Priority label (`production` / `economy`) |
| `x-route-target` | Backend pool the request was routed to (`ptu-gate` / `payg`) |
| `x-backend-type` | Which backend type served the request (`ptu` / `payg`) |
| `x-ratelimit-remaining-tokens` | Remaining tokens in the current per-minute window |
| `x-quota-remaining-tokens` | Remaining tokens in the monthly quota (non-P1 only) |
| `x-ptu-utilization` | Global PTU utilization for the model |
| `x-ptu-consumed` / `x-ptu-limit` | Per-team PTU usage and allocation |

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
- **[JWT Citadel Adaptation](docs/jwt-citadel-implementation.md)** — How this project adapts the Citadel access contracts pattern

## Research Sources

| Source | Link |
|--------|------|
| Citadel (AI Hub Gateway) | [`Azure-Samples/ai-hub-gateway-solution-accelerator`](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) (citadel-v1 branch) |
| AI-Gateway | `Azure-Samples/AI-Gateway` |
| GenAI Playbook | [MS Learn: Maximize PTU Utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization) |
| ai-gw-v2 | [`Heenanl/ai-gw-v2`](https://github.com/Heenanl/ai-gw-v2) (usecaseonboard / jwtauth branches) |
| SimpleL7Proxy | [`microsoft/SimpleL7Proxy`](https://github.com/microsoft/SimpleL7Proxy) |
| ai-policy-engine | [`Azure-Samples/ai-policy-engine`](https://github.com/Azure-Samples/ai-policy-engine) — ASP.NET 10 + APIM reference for AI governance with per-tenant billing (Redis + CosmosDB), monthly quotas, RPM/TPM limits, and a React dashboard. Heavier infrastructure than this project but stronger on chargeback/billing. No explicit PTU/PAYG priority routing. |
