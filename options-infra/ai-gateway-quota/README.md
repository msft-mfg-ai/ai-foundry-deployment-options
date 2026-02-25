# Option: AI Gateway with Bearer Token Auth + Quota Tiers

This deployment creates an **Azure API Management (APIM)** AI Gateway with **Entra ID app registrations** for client authentication. Client applications authenticate with **bearer tokens** (client credentials flow), are identified by the **`azp` claim**, and are subject to **per-caller token quotas** enforced via the `llm-token-limit` policy with tiered TPM limits and monthly token budgets (Gold / Silver / Bronze).

## Features

- **JWT Bearer Token Auth** — `validate-azure-ad-token` against Entra ID
- **Caller Identification** — `azp` claim maps to caller name and tier
- **Tiered TPM Quotas** — Gold (200K), Silver (50K), Bronze (10K) tokens per minute
- **Monthly Token Budgets** — Native enforcement via `llm-token-limit` with `token-quota-period=Monthly`
- **Response Headers** — `x-ratelimit-remaining-tokens`, `x-ratelimit-limit-tokens`, `x-caller-tier`, `x-caller-name`
- **Azure Portal Dashboard** — Quota overview, usage charts, rate limit events, burn-down
- **Entra ID via Bicep** — App registrations using Microsoft Graph Bicep extension

## Architecture Overview

```
                    ┌──────────────────────────────────────────────────────────────────────────────────┐
                    │                              This Deployment                                      │
                    │                                                                                   │
  Client App        │    ┌──────────────────────────────────────────────────────┐                       │
  (Entra ID)        │    │           Entra ID                                   │                       │
       │            │    │  Gateway App (audience)                              │                       │
       │ 1. Get     │    │  Team Apps (client_id → azp claim)                  │                       │
       ├──token────►│    │  Service Principals                                 │                       │
       │            │    └──────────────────────────────────────────────────────┘                       │
       │            │                    ▲ validate-azure-ad-token                                      │
       │            │                    │                                                              │
       │            │    ┌───────────────┴──────────────────────────────────────────────────────────┐   │
       │            │    │            Azure API Management (AI Gateway)                             │   │
       │ 2. Call    │    │                                                                          │   │
       │ API with   │    │  1. validate-azure-ad-token   ──→  Verify JWT against Entra ID           │   │
       │ Bearer     │    │  2. Extract azp claim          ──→  Identify caller application           │   │
       └──token────►│    │  3. Lookup caller tier          ──→  Named Value: azp → {tier, name}      │   │
                    │    │  4. Authorization check         ──→  Reject unknown callers (403)          │   │
                    │    │  5. llm-token-limit             ──→  TPM quota + monthly token budget       │   │
                    │    │  6. Forward to backend           ──→  Managed identity auth to Azure OpenAI │   │
                    │    └───────────────────────────────────────────────┬──────────────────────────┘   │
                    │                                                    │                              │
                    │    ┌──────────────────────────────────────────────┼────────────────────────────┐  │
                    │    │  Supporting Services                         │                            │  │
                    │    │  Log Analytics │ App Insights │ Dashboard    │                            │  │
                    │    └──────────────────────────────────────────────┼────────────────────────────┘  │
                    └───────────────────────────────────────────────────┼────────────────────────────────┘
                                                                       │
                                                    (Public Internet)  │
                                                                       ▼
                                              ┌──────────────────────────────────────┐
                                              │   External: Azure OpenAI             │
                                              │   (Landing Zone / Shared Resource)   │
                                              └──────────────────────────────────────┘
```

## Request Flow

1. **Client application** obtains a bearer token from Entra ID (MSAL client credentials flow)
2. Client sends request to APIM with `Authorization: Bearer <token>`
3. APIM **validates the JWT** against Entra ID (`validate-azure-ad-token` policy)
4. **`azp` claim** is extracted — this is the client application's App ID
5. Gateway **checks authorization**: looks up the `azp` in the caller-tier-mapping Named Value
   - If the caller is not in the mapping → **403 Forbidden**
6. Gateway **checks quota**: applies `llm-token-limit` with tier-specific TPM limits and monthly token budget
   - If TPM quota exceeded → **429 Too Many Requests**
   - If monthly token quota exceeded → **403 Quota Exceeded**
7. Request is **forwarded to Azure OpenAI** using APIM's managed identity

## Entra ID App Registrations

The deployment automatically creates Entra ID app registrations via the [Microsoft Graph Bicep extension](https://learn.microsoft.com/en-us/graph/templates/bicep/quickstart-create-bicep-interactive-mode):

| App | Purpose | Bicep Resource |
|-----|---------|----------------|
| **Gateway App** | Audience — APIM validates tokens against this | `entra/entra-apps.bicep` |
| **Team Alpha** | Caller app — Gold tier (200K TPM) | `entra/entra-apps.bicep` |
| **Team Beta** | Caller app — Silver tier (50K TPM) | `entra/entra-apps.bicep` |
| **Team Gamma** | Caller app — Bronze tier (10K TPM) | `entra/entra-apps.bicep` |

Client secrets are created post-deploy via `scripts/add_app_reg_secrets.sh` (following the [agents-workshop pattern](https://github.com/karpikpl/agents-workshop/blob/main/scripts/add_app_reg_secret.sh)) and stored in `azd env`.

## Quota Tiers

| Tier     | Tokens Per Minute (TPM) | Description               |
|----------|------------------------|---------------------------|
| **Gold**   | 200,000                | High-priority teams       |
| **Silver** | 50,000                 | Standard teams            |
| **Bronze** | 10,000                 | Low-priority / dev teams  |

Quota is tracked per caller (using the `azp` claim as the counter key), so each application gets its own independent quota within its tier.

### Customizing Tiers

Tier TPM limits and monthly quotas are defined in the `caller-tier-mapping` Named Value (sourced from `entra/entra-apps.bicep`). The policy reads TPM and monthly quota dynamically:

```xml
<llm-token-limit
    counter-key="@((string)context.Variables["azp"])"
    tokens-per-minute="@(int.Parse((string)context.Variables["caller-tpm"]))"
    token-quota="@(long.Parse((string)context.Variables["caller-monthly-quota"]))"
    token-quota-period="Monthly"
    estimate-prompt-tokens="true" ... />
```

## Prerequisites

### 1. Azure OpenAI Resource

```bash
export OPENAI_API_BASE="https://your-openai.openai.azure.com/"
export OPENAI_RESOURCE_ID="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>"
```

### 2. Permissions

The deploying user needs:
- **Application.ReadWrite.All** (or `Application.ReadWrite.OwnedBy`) — for creating Entra ID app registrations via the Microsoft Graph Bicep extension
- Contributor access to the target Azure subscription

## Deployment

```bash
cd options-infra/ai-gateway-quota

export OPENAI_API_BASE="https://your-openai.openai.azure.com/"
export OPENAI_RESOURCE_ID="/subscriptions/..."

azd up
```

The deployment:
1. Creates Entra ID app registrations (gateway + 3 team apps)
2. Deploys APIM with the quota policy, backends, and monitoring
3. Post-provision hook creates client secrets and stores them in `azd env`

## Testing

### Install Python dependencies

```bash
cd scripts
pip install -r requirements.txt
```

### Generate a token

```bash
python generate_token.py --from-azd alpha --decode
```

You can also specify credentials explicitly:

```bash
python generate_token.py \
    --tenant-id <TENANT_ID> \
    --client-id <CLIENT_ID> \
    --client-secret <CLIENT_SECRET> \
    --audience <AUDIENCE> \
    --decode
```

### Call the gateway directly

```bash
TOKEN=$(python generate_token.py --from-azd alpha)

curl -s https://<apim-gateway>/inference/openai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-02-01 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```

### Simulate multi-team traffic

1. Create config from `azd env` values:
   ```bash
   cp config_sample.json config.json
   # Fill in values from: azd env get-values
   ```

2. Run the simulation:
   ```bash
   python simulate_traffic.py --config config.json --requests-per-team 10 --model gpt-4.1-mini
   ```

## Monitoring

### Token Usage by Caller

```kql
ApiManagementGatewayLogs
| where ApiId == "inference-api"
| extend callerName = tostring(parse_json(RequestHeaders)["x-caller-name"])
| extend callerTier = tostring(parse_json(RequestHeaders)["x-caller-tier"])
| extend callerAzp = tostring(parse_json(RequestHeaders)["x-caller-azp"])
| summarize RequestCount=count(), AvgLatency=avg(TotalTime) by callerName, callerTier, ResponseCode
| order by callerName asc
```

### Rate Limit Events

```kql
ApiManagementGatewayLogs
| where ResponseCode == 429
| extend callerName = tostring(parse_json(RequestHeaders)["x-caller-name"])
| extend callerTier = tostring(parse_json(RequestHeaders)["x-caller-tier"])
| summarize RateLimitedCount=count() by callerName, callerTier, bin(Timestamp, 1m)
| order by Timestamp desc
```

## Monthly Token Budgets

In addition to per-minute TPM quotas, the gateway enforces **monthly token budgets** natively using the `llm-token-limit` APIM policy.

### How It Works

1. Monthly quota values (`monthlyQuota`) are defined per caller in the **`caller-tier-mapping`** Named Value alongside tier and TPM settings
2. The `llm-token-limit` policy reads each caller's `monthlyQuota` at request time and applies it with `token-quota-period="Monthly"`
3. APIM tracks token consumption natively — no external components (Logic App, KQL alerts, or custom tables) are required
4. When a caller exceeds their monthly budget, the policy returns **403** automatically
5. Counters reset at the start of each calendar month

### Configuring Monthly Budgets

Monthly quotas are defined in `entra/entra-apps.bicep` as part of the `callerTierMapping` output:

```bicep
// Example: Team Alpha gets 10M tokens/month, Gold tier at 200K TPM
{"<azp>": {"tier": "gold", "name": "Team Alpha", "tpm": 200000, "monthlyQuota": 10000000}}
```

Default budgets:
| Team | Tier | Monthly Token Budget |
|------|------|---------------------|
| Team Alpha | Gold | 10,000,000 |
| Team Beta | Silver | 5,000,000 |
| Team Gamma | Bronze | 100 (test value) |

To change a budget, update the `monthlyQuota` value in `entra/entra-apps.bicep` and redeploy.

### Response Headers

Every successful response includes:

| Header | Description |
|--------|-------------|
| `x-ratelimit-remaining-tokens` | Remaining TPM quota for this minute |
| `x-ratelimit-limit-tokens` | TPM limit for caller's tier |
| `x-quota-remaining-tokens` | Remaining monthly token quota |
| `x-quota-limit-tokens` | Monthly token quota limit |
| `x-caller-tier` | Caller's tier (gold/silver/bronze) |
| `x-caller-name` | Caller's display name |

## Dashboard

The deployment includes an Azure Portal dashboard with:

- **Quota Overview** — Monthly usage per caller with tier and TPM limit
- **Token Usage Over Time** — Hourly stacked column chart by caller
- **Rate Limit Events** — 429 throttle counts per caller
- **Error Breakdown** — 4xx/5xx errors by caller and status code
- **Model Usage by Caller** — Token consumption per model/deployment
- **Daily Usage** — Daily breakdown with tier info
- **Monthly Burn-Down** — Cumulative token chart for budget tracking

Find the dashboard in the Azure Portal under **Dashboards** → "AI Gateway - Quota Tiers Dashboard".
