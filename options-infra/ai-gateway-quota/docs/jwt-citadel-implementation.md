# JWT-Based Citadel Access Contracts — Implementation Plan

## Problem Statement

We want to adopt [Citadel's Access Contracts](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) pattern for governing AI model access across multiple internal teams, but with a critical constraint:

> **Authentication is JWT-only. No APIM subscription keys. No APIM Products.**

Teams (apps) are identified solely by JWT claims (`azp`, `appid`, `xms_mirid`, etc.) issued by Entra ID. Each team is granted a **virtual TPM limit** on specific Foundry instances/models — including PTU deployments.

### Environment

| Component | Details |
|---|---|
| **AI Models** | Multiple Azure AI Foundry instances, each with different models. Each instance can have PTU and standard (PAYG) deployments for the same model. |
| **Auth** | Entra ID JWT tokens. Callers identified by `azp`/`appid` (app registrations) or `xms_mirid` (managed identities). |
| **Gateway** | Azure API Management (single API, no Products/Subscriptions) |
| **Identity claim** | `azp`, `appid`, `xms_mirid`, `oid`, or `sub` claim in the JWT identifies the calling team/app |
| **Backend auth** | APIM Managed Identity → Foundry (no cognitive services keys) |

### What We Keep from Citadel

| Citadel Feature | Keep? | Adaptation |
|---|---|---|
| Access Contract JSON schema | ✅ | Replace `infrastructure.apim.subscriptionId` with multi-identity `identities` array |
| Per-team model access control | ✅ | JWT claim → allowed models lookup (cache, not Product) |
| Per-team TPM + quota limits | ✅ | `counter-key` = JWT claim instead of `context.Subscription.Id`; per-model TPM via `models` map |
| Backend pool routing (priority/weight) | ✅ | No change — same Bicep modules |
| Circuit breaker on 429 | ✅ | No change |
| APIM Products per contract | ❌ | Replaced by JWT claim → config lookup |
| APIM Subscription keys | ❌ | Not used |
| Key Vault for subscription keys | ❌ | Not needed (no keys to store) |
| Foundry Connection with APIM sub key | ❌ | Foundry uses Entra ID auth directly |
| Content safety (optional) | ✅ | No change |
| PII handling (optional) | ✅ | No change |

---

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                        APIM Gateway (Single API)                      │
│                                                                       │
│  1. validate-jwt → extract caller claims                              │
│  2. Extract JWT claims (azp, appid, xms_mirid) →                      │
│     prefix-match against identities array → resolve contract          │
│  3. Enforce: per-model TPM (hard 429), monthly quota (cost cap)       │
│  4. Check PTU quota (per-model PTU TPM, soft redirect to standard)     │
│  5. Three-priority routing (+ PTU quota check):                       │
│     P1 (production) → PTU pool IF PTU quota available, else PAYG overflow │
│     P2 (standard)   → PTU when utilization < 50% AND PTU quota available │
│     P3 (economy)    → Always PAYG pool                                │
│  6. Backend auth: APIM Managed Identity → Foundry                     │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  Access Contract Config (Azure Blob Storage, APIM-cached 5 min) │  │
│  │                                                                 │  │
│  │  "contracts": {                                                 │  │
│  │    "Team A Production": {                                       │  │
│  │      "priority": 1,        ← PTU first (with quota cap)        │  │
│  │      "models": {           ← replaces allowedModels + tpmLimit  │  │
│  │        "gpt-52-chat":       { "tpm": 8000, "ptuTpm": 4000 },   │  │
│  │        "text-embedding-3":  { "tpm": 20000 }                   │  │
│  │      },                                                        │  │
│  │      "monthlyQuota": 4000000  ← cost cap across all models     │  │
│  │    }                                                            │  │
│  │  },                                                             │  │
│  │  "identities": [            ← flat lookup table for matching    │  │
│  │    { "value": "a1b2c3d4-...", "claimName": "azp",               │  │
│  │      "displayName": "Team A App",                               │  │
│  │      "contract": "Team A Production" },                         │  │
│  │    { "value": "/subscriptions/.../userAssignedIdentities/...",   │  │
│  │      "claimName": "xms_mirid",                                  │  │
│  │      "displayName": "Team A MI",                                │  │
│  │      "contract": "Team A Production" }                          │  │
│  │  ]                                                              │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌──────────────────────────┐     ┌───────────────────────┐           │
│  │ APIM Internal Cache      │     │ Backend Pools         │           │
│  │                          │     │                       │           │
│  │ ptu-remaining:           │     │ gpt52chat-pool:       │           │
│  │   gpt-52-chat: 45231     │────►│   P1: PTU deploys     │           │
│  │   (global utilization)   │     │   P2: PAYG deploys    │           │
│  │                          │     │                       │           │
│  │ ptu-consumed:            │     │ gpt52chat-payg-pool:  │           │
│  │   team-a:gpt-52-chat: 3K │     │   PAYG deployments    │           │
│  │   team-b:gpt-52-chat: 8K │     └───────────────────────┘           │
│  │   (per-contract PTU use) │                                         │
│  └──────────────────────────┘                                         │
└───────────────────────────────────────────────────────────────────────┘
```

### Request Flow

```
Client (Team A prod app)
  │
  │  Authorization: Bearer <JWT with appid="a1b2c3d4-..." or xms_mirid="/subscriptions/...">
  │  POST /openai/deployments/gpt-52-chat/chat/completions
  │
  ▼
APIM Inbound Policy
  │
  ├─ 1. validate-jwt → store as context variable "jwt"
  │
  ├─ 2. Extract caller claims: azp, appid, xms_mirid, oid, sub
  │  2b. Load contracts JSON from Blob Storage (APIM cache, 5 min TTL)
  │      Iterate identities array, find first entry where
  │      caller's claim[identity.claimName] starts with identity.value
  │  2c. Look up matched contract by name from contracts map
  │      contracts[matchedIdentity.contract] → { priority, models, monthlyQuota, ... }
  │      If no identity matched → 403 "Unknown application"
  │
  ├─ 3. Validate model access (via models map)
  │     If requestedModel NOT IN contract.models → 403 "Model not authorized"
  │     Also extracts per-model config: model-config = contract.models[requestedModel]
  │
  ├─ 4. Enforce per-model TPM + monthly quota via two llm-token-limit calls:
  │     A) Per-model TPM: counter-key="caller-name:model", tpm=model-config.tpm (hard 429)
  │     B) Monthly quota: counter-key="caller-name", token-quota=monthlyQuota (cost cap)
  │     Either exceeds → 429 to client
  │     NOTE: counter-key uses contract name (caller-name), so all identities
  │           under one contract share quota.
  │
  ├─ 5. Read PTU state from cache:
  │     A) Global PTU utilization: "ptu-remaining:{model}" → last x-ratelimit-remaining-tokens
  │        from PTU response (cached 60s, set by outbound policy)
  │     B) Per-contract PTU consumption: "ptu-consumed:{caller-name}:{model}" → tokens used on PTU
  │     PTU quota available? = ptuConsumed < contract.models[model].ptuTpm
  │
  └─ 6. Priority-based routing (requires BOTH priority AND PTU quota):
        ┌─── priority == 1 AND ptuQuotaAvailable ──► {model}-pool
        │    priority == 1 AND PTU quota exhausted ──► {model}-payg-pool (soft overflow)
        │
        ├─── priority == 2 AND ptuQuotaAvailable AND utilization < 50% ──► {model}-pool
        │    priority == 2 AND (no quota OR utilization ≥ 50%) ──► {model}-payg-pool
        │
        └─── priority == 3 ──► {model}-payg-pool (always PAYG)

APIM Outbound Policy (when response came from PTU)
  │
  ├─ Cache x-ratelimit-remaining-tokens → "ptu-remaining:{model}", TTL: 60s
  │  (feeds global utilization for P2 decisions)
  │
  └─ Increment per-contract PTU counter → "ptu-consumed:{caller-name}:{model}", TTL: 60s
     (feeds PTU quota check for this contract's next request)
```

---

## Access Contract Schema (JWT-Adapted)

The original Citadel `access-contract-request.schema.json` is adapted to remove APIM Product/Subscription dependencies and add JWT identity:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "JWT Access Contract",
  "type": "object",
  "required": ["contractInfo", "identity", "policies"],
  "properties": {
    "contractInfo": {
      "type": "object",
      "required": ["businessUnit", "useCaseName", "environment"],
      "properties": {
        "businessUnit": {
          "type": "string",
          "description": "Business unit (e.g., 'Sales', 'Engineering')"
        },
        "useCaseName": {
          "type": "string",
          "description": "Use case name (e.g., 'ProdAssistant', 'DevTest')"
        },
        "environment": {
          "type": "string",
          "enum": ["DEV", "TEST", "UAT", "STAGING", "PROD"]
        },
        "description": {
          "type": "string"
        }
      }
    },
    "identity": {
      "type": "object",
      "description": "Multi-identity support — replaces APIM subscription. Supports app registrations, managed identities, and any Entra identity.",
      "required": ["identities"],
      "properties": {
        "identities": {
          "type": "array",
          "description": "One or more identities that map to this contract. Each identity specifies a JWT claim name and value. Prefix matching is used — e.g., a subscription prefix in xms_mirid matches all managed identities in that subscription.",
          "items": {
            "type": "object",
            "required": ["value", "claimName"],
            "properties": {
              "value": {
                "type": "string",
                "description": "The claim value to match (exact or prefix). E.g., a client_id GUID for azp/appid, or a resource ID path for xms_mirid."
              },
              "displayName": {
                "type": "string",
                "description": "Human-readable name for this identity (e.g., 'Team A Production App')"
              },
              "claimName": {
                "type": "string",
                "description": "JWT claim used to match this identity. One of: azp, appid, xms_mirid, oid, sub."
              }
            }
          }
        }
      }
    },
    "policies": {
      "type": "object",
      "properties": {
        "priority": {
          "type": "integer",
          "enum": [1, 2, 3],
          "description": "1=Production, 2=Standard, 3=Economy"
        },
        "models": {
          "type": "array",
          "description": "Allowed models and their per-model TPM/PTU limits. Models not in this array are denied (403). Serves double duty: defines allowed models AND their rate limits.",
          "items": {
            "type": "object",
            "required": ["name", "tpm"],
            "properties": {
              "name": {
                "type": "string",
                "description": "Model deployment name (e.g., 'gpt-52-chat')"
              },
              "tpm": {
                "type": "integer",
                "description": "Tokens per minute for this model (hard limit — 429 if exceeded)"
              },
              "ptuTpm": {
                "type": "integer",
                "description": "Max TPM routed to PTU for this model. Soft limit — overflow goes to PAYG, not 429. Omit or set to 0 for standard-only models (no PTU deployments)."
              }
            }
          }
        },
        "monthlyQuota": {
          "type": "integer",
          "description": "Monthly token quota across all models (cost cap). Enforced via llm-token-limit with counter-key=caller-name (contract name)."
        },
        "contentSafety": {
          "type": "object",
          "description": "Same as Citadel — no changes needed"
        },
        "piiHandling": {
          "type": "object",
          "description": "Same as Citadel — no changes needed"
        }
      }
    }
  }
}
```

### Supported Identity Types

The `identities` array supports multiple identity types via different JWT claims. Each identity entry specifies a `claimName` to match against and a `value` that uses **prefix matching** — the caller's claim value must start with the identity's `value`.

| Claim | Identity Type | Example Value | Notes |
|---|---|---|---|
| `azp` / `appid` | App registration (v2/v1 tokens) | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` | Exact match (GUIDs don't have meaningful prefixes). `azp` is the v2 token claim, `appid` is v1. |
| `xms_mirid` | Managed identity (system or user-assigned) | `/subscriptions/.../Microsoft.ManagedIdentity/userAssignedIdentities/my-mi` | Prefix matching is powerful here — match all managed identities in a resource group or subscription by using a shorter prefix. |
| `oid` | Any Entra identity (object ID) | `f1e2d3c4-b5a6-7890-abcd-ef1234567890` | Matches any Entra identity by object ID. Useful as a catch-all. |
| `sub` | Subject claim | `f1e2d3c4-b5a6-7890-abcd-ef1234567890` | Subject identifier. Often same as `oid` for service principals. |

> **Prefix matching for `xms_mirid`**: The `xms_mirid` claim contains the full Azure resource ID of a managed identity. By using a prefix like `/subscriptions/aaaa-bbbb/resourceGroups/my-rg/`, you can match **all** managed identities in that resource group under a single contract — no need to enumerate each one.

### Example Contracts

#### Team A — Production (Priority 1: always PTU)

```json
{
  "contractInfo": {
    "businessUnit": "Sales",
    "useCaseName": "CustomerAssistant",
    "environment": "PROD",
    "description": "Production sales assistant — always routes to PTU"
  },
  "identity": {
    "identities": [
      {
        "value": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        "displayName": "Team A Production App",
        "claimName": "azp"
      },
      {
        "value": "/subscriptions/aaaa-bbbb-cccc/resourceGroups/team-a-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/team-a-mi",
        "displayName": "Team A Managed Identity",
        "claimName": "xms_mirid"
      }
    ]
  },
  "policies": {
    "priority": 1,
    "models": [
      { "name": "gpt-52-chat", "tpm": 8000, "ptuTpm": 4000 },
      { "name": "text-embedding-3-large", "tpm": 20000 }
    ],
    "monthlyQuota": 4000000
  }
}
```

> **Reading this contract**: Team A has **two identities** — an app registration (matched via `azp`) and a managed identity (matched via `xms_mirid`). Both identities share the same contract: **8,000 TPM on `gpt-52-chat`** (hard 429), of which **at most 4,000 TPM** flows through PTU. Once the PTU allocation is consumed, additional requests spill to PAYG (still within the 8K per-model cap). They also get 20K TPM on embeddings (no `ptuTpm` — embeddings are PAYG-only). A **4M monthly token quota** caps total cost across all models. Because both identities share the same contract name as counter-key, quota is shared.

#### Team B — Standard (Priority 2: PTU when available, PAYG when busy)

```json
{
  "contractInfo": {
    "businessUnit": "Engineering",
    "useCaseName": "DevPlayground",
    "environment": "DEV",
    "description": "Standard — uses PTU idle capacity, falls back to PAYG when PTU > 50%"
  },
  "identity": {
    "identities": [
      {
        "value": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
        "displayName": "Team B Dev App",
        "claimName": "azp"
      }
    ]
  },
  "policies": {
    "priority": 2,
    "models": [
      { "name": "gpt-52-chat", "tpm": 20000, "ptuTpm": 10000 }
    ],
    "monthlyQuota": 1000000
  }
}
```

> **Reading this contract**: Team B gets **20K TPM on `gpt-52-chat`**, of which **10K TPM can be PTU** (only when PTU utilization < 50%). Once their PTU allocation is consumed, all requests go to PAYG. A **1M monthly quota** caps total cost.

#### Team C — Economy (Priority 3: always PAYG)

```json
{
  "contractInfo": {
    "businessUnit": "DataScience",
    "useCaseName": "EconomyEmbeddings",
    "environment": "PROD",
    "description": "Economy embedding jobs — always PAYG, never competes for PTU"
  },
  "identity": {
    "identities": []
  },
  "policies": {
    "priority": 3,
    "models": [
      { "name": "gpt-52-chat", "tpm": 5000 },
      { "name": "text-embedding-3-large", "tpm": 5000 }
    ],
    "monthlyQuota": 200000
  }
}
```

> **Reading this contract**: Team C has **empty identities** (auto-created contract, identities to be added later). Gets **5K TPM on `gpt-52-chat`** and **5K TPM on embeddings**, all on PAYG. No `ptuTpm` — P3 (economy) teams never touch PTU. A **200K monthly quota** caps total cost.


---

## Three-Priority Routing Model

The core routing logic uses three priority tiers with distinct PTU/PAYG behavior. Each tier is **also gated by the team's per-model PTU TPM** (`models[model].ptuTpm`):

| Priority | Name | PTU Routing | PAYG Routing | Use Case |
|---|---|---|---|---|
| **P1** | Production | ✅ PTU first, **up to `ptuTpm`** | Overflow when PTU quota consumed OR on 429 | Production workloads — PTU is reserved for these, capped per model per team |
| **P2** | Standard | ✅ PTU when utilization < 50% **AND `ptuTpm` not exhausted** | Direct to PAYG when PTU busy or PTU quota consumed | Standard, staging — uses PTU idle capacity within allocation |
| **P3** | Economy | ❌ Never PTU | ✅ Always PAYG | Batch processing, experiments — never competes for PTU |

### How It Works

```bash
                    ┌──────────────────┐     ┌──────────────────┐
                    │ APIM Cache:      │     │ APIM Cache:      │
                    │ PTU remaining    │     │ PTU consumed     │
                    │ tokens (global)  │     │ per team (quota) │
                    │ (updated on      │     │ (updated on      │
                    │ every PTU resp)  │     │ every PTU resp)  │
                    └────────┬─────────┘     └────────┬─────────┘
                             │ read                   │ read
                             ▼                        ▼
  ┌─────────┐     ┌───────────────────────────────────────────────┐
  │  Client  │────►│             APIM Inbound Policy               │
  │ (JWT)    │     │                                               │
  └─────────┘     │  1. validate-jwt → extract claims              │
                  │  2. Match identities → load contract             │
                  │  3. Enforce per-model TPM (hard 429) + monthly quota │
                  │  4. Check PTU quota (ptuConsumed < model ptuTpm)  │
                  │  5. Priority routing:                          │
                  │     ┌────────────────────────────────────────┐ │
                  │     │ P1 + PTU quota OK → PTU pool           │ │
                  │     │ P1 + PTU quota FULL → std (overflow)   │ │
                  │     │ P2 + PTU quota OK + <70% → PTU pool    │ │
                  │     │ P2 + (no quota OR ≥70%) → std pool     │ │
                  │     │ P3 → standard pool (always)            │ │
                  │     └────────────────────────────────────────┘ │
                  └──────────────┬────────────────┬───────────────┘
                                 │                │
                            PTU pool         standard pool
                            (P1/P2 with      (P1 overflow,
                             PTU quota)       P2 fallback, P3)
                                 │                │
                           ┌─────▼──────┐   ┌─────▼──────┐
                           │ Foundry    │   │ Foundry    │
                           │ PTU        │   │ PAYG       │
                           │ (East US)  │   │ (West US)  │
                           └─────┬──────┘   └────────────┘
                                 │
                        outbound: update both caches
                        1. ptu-remaining:{model} (global)
                        2. ptu-consumed:{caller-name}:{model} (per-contract)
```

### The 70% Threshold

The PTU `x-ratelimit-remaining-tokens` header reports **remaining capacity in the current 1-minute window**. A PTU with 100K TPM capacity at 70% utilization has ~30K tokens remaining.

- **> 50% remaining** (< 50% utilized): P2 traffic can safely use PTU without starving P1
- **≤ 50% remaining** (≥ 50% utilized): PTU headroom is low — P2 diverted to PAYG to protect P1
- **PTU returns 429**: P1 requests spill to PAYG via backend pool circuit breaker

The threshold is configurable via the `{{ptu-utilization-threshold}}` Named Value (default: `0.5`).

> **Why 50%?** It provides a 50% safety buffer for P1 burst traffic. If P1 suddenly spikes, there's headroom before 429s. Adjust based on observed traffic patterns — lower threshold = more PAYG cost but better P1 protection; higher threshold = better PTU utilization but more P1 429 risk.

---

## APIM Policy Implementation

### Key Differences from Citadel

| Citadel (Original) | JWT Citadel (This Plan) |
|---|---|
| `counter-key="@(context.Subscription.Id)"` | `counter-key="@((string)context.Variables["caller-name"])"` (contract name — shared across all identities in a contract) |
| Product-level policy (per product XML) | Single API-level policy with `<choose>` on JWT claims |
| Model access via `allowedModels` set-variable in product policy | Model access via `models` map lookup (also provides per-model TPM) |
| Identity from subscription key header | Identity from `Authorization: Bearer` header |
| All priorities route to same backend pool | P1→{model}-pool, P2→{model}-pool/{model}-payg-pool dynamic, P3→{model}-payg-pool always |
| No utilization awareness | `x-ratelimit-remaining-tokens` cached for P2 decisions |

### Policy 1: Complete API-Level Policy (Inbound + Backend + Outbound)

This is the **full production policy** — a single XML applied at the API level. It handles JWT auth, contract lookup, token limits, 3-priority routing, and utilization caching.

```xml
<!--
  JWT Access Contract Policy with 3-Priority PTU/PAYG Routing
  
  Apply at: API level (not Product level — we don't use Products)
  Prerequisites:
    - Bicep deploy-time: tenant-id, api-audience (hardcoded as https://cognitiveservices.azure.com)
    - Bicep deploy-time: {{contracts-blob-url}} — Blob Storage URL for compiled contracts JSON
    - Named Value: {{ptu-utilization-threshold}} — e.g., "0.5" (default)
    - Backend:     {model}-pool           — Mixed pool: PTU backends (P1) + PAYG backends (P2). Circuit breaker on 429.
    - Backend:     {model}-payg-pool       — PAYG-only pool for P2 overflow and P3 economy routing.
    - Fragment:    set-llm-requested-model — Citadel fragment (extracts model from request)
    - Fragment:    set-backend-authorization — Citadel fragment (sets managed identity auth)
-->
<policies>
  <inbound>
    <base />

    <!-- ================================================================ -->
    <!-- STEP 1: JWT Validation and Identity Extraction                   -->
    <!-- ================================================================ -->
    <validate-jwt
      header-name="Authorization"
      output-token-variable-name="jwt"
      failed-validation-httpcode="401"
      failed-validation-error-message="Invalid or missing JWT token">
      <openid-config url="https://login.microsoftonline.com/{{tenant-id}}/v2.0/.well-known/openid-configuration" />
      <audiences>
        <!-- Use Cognitive Services audience so Foundry-integrated clients work natively -->
        <audience>https://cognitiveservices.azure.com</audience>
      </audiences>
      <issuers>
        <issuer>https://login.microsoftonline.com/{{tenant-id}}/v2.0</issuer>
        <issuer>https://sts.windows.net/{{tenant-id}}/</issuer>
      </issuers>
    </validate-jwt>

    <!-- Extract caller identity claims: try multiple claim types for broad identity support -->
    <set-variable name="caller-azp" value="@{
      var jwt = (Jwt)context.Variables["jwt"];
      return jwt.Claims.GetValueOrDefault("azp",
             jwt.Claims.GetValueOrDefault("appid", ""));
    }" />
    <set-variable name="caller-xms-mirid" value="@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("xms_mirid", ""))" />
    <set-variable name="caller-oid" value="@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("oid", ""))" />
    <set-variable name="caller-sub" value="@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("sub", ""))" />

    <!-- Fallback caller-id for logging (first non-empty claim) -->
    <set-variable name="caller-id" value="@{
      var azp = (string)context.Variables["caller-azp"];
      if (!string.IsNullOrEmpty(azp)) return azp;
      var mirid = (string)context.Variables["caller-xms-mirid"];
      if (!string.IsNullOrEmpty(mirid)) return mirid;
      var oid = (string)context.Variables["caller-oid"];
      if (!string.IsNullOrEmpty(oid)) return oid;
      return (string)context.Variables["caller-sub"];
    }" />

    <!-- ================================================================ -->
    <!-- STEP 2: Load Access Contract via Identity Prefix Matching         -->
    <!--                                                                  -->
    <!-- Contract config is stored in Azure Blob Storage with two keys:   -->
    <!-- "contracts" (name → config) and "identities" (flat lookup table).-->
    <!-- APIM fetches via managed identity and caches the raw JSON string -->
    <!-- internally for 5 minutes. On cache hit, the blob is not fetched. -->
    <!-- JObject.Parse runs on every request (raw string is cached, not   -->
    <!-- the parsed object). For <100 teams this is sub-millisecond.      -->
    <!-- For very large deployments, consider caching the resolved        -->
    <!-- contract per caller identity.                                    -->
    <!-- ================================================================ -->

    <!-- Check APIM internal cache first -->
    <cache-lookup-value key="contracts-blob-cache" variable-name="contractsJson" />
    <choose>
      <when condition="@(!context.Variables.ContainsKey("contractsJson"))">
        <!-- Cache miss: fetch from blob storage using managed identity -->
        <send-request mode="new" response-variable-name="contractsBlobResponse" timeout="10">
          <set-url>{{contracts-blob-url}}</set-url>
          <set-method>GET</set-method>
          <authentication-managed-identity resource="https://storage.azure.com/" />
        </send-request>
        <set-variable name="contractsJson" value="@(((IResponse)context.Variables["contractsBlobResponse"]).Body.As<string>())" />
        <!-- Cache the raw JSON string for 5 minutes -->
        <cache-store-value key="contracts-blob-cache" value="@((string)context.Variables["contractsJson"])" duration="300" />
      </when>
    </choose>

    <set-variable name="caller-name" value="@{
      var configRoot = JObject.Parse((string)context.Variables["contractsJson"]);
      var identities = (JArray)configRoot["identities"];
      var azp = (string)context.Variables["caller-azp"];
      var mirid = (string)context.Variables["caller-xms-mirid"];
      var oid = (string)context.Variables["caller-oid"];
      var sub = (string)context.Variables["caller-sub"];

      foreach (var identity in identities) {
        var claimName = identity["claimName"]?.Value<string>() ?? "";
        var value = identity["value"]?.Value<string>() ?? "";
        string callerValue = "";
        if (claimName == "azp" || claimName == "appid") callerValue = azp;
        else if (claimName == "xms_mirid") callerValue = mirid;
        else if (claimName == "oid") callerValue = oid;
        else if (claimName == "sub") callerValue = sub;

        if (!string.IsNullOrEmpty(callerValue) && callerValue.StartsWith(value)) {
          return identity["contract"]?.Value<string>() ?? "";
        }
      }
      return "";
    }" />

    <set-variable name="contract" value="@{
      var callerName = (string)context.Variables["caller-name"];
      if (string.IsNullOrEmpty(callerName)) return "";
      var configRoot = JObject.Parse((string)context.Variables["contractsJson"]);
      var contracts = (JObject)configRoot["contracts"];
      var contract = contracts[callerName];
      return contract != null ? contract.ToString() : "";
    }" />

    <!-- Reject unknown applications -->
    <choose>
      <when condition="@(string.IsNullOrEmpty((string)context.Variables["contract"]))">
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>@{
            return new JObject(
              new JProperty("error", new JObject(
                new JProperty("code", "UnknownApplication"),
                new JProperty("message", $"No access contract matched for caller '{context.Variables["caller-id"]}'. Contact the platform team.")
              ))
            ).ToString();
          }</set-body>
        </return-response>
      </when>
    </choose>

    <!-- Parse contract fields into typed variables -->
    <set-variable name="contractObj" value="@(JObject.Parse((string)context.Variables["contract"]))" />
    <set-variable name="priority" value="@(((JObject)context.Variables["contractObj"])["priority"]?.Value<int>() ?? 2)" />
    <set-variable name="contract-models" value="@{
      var models = ((JObject)context.Variables["contractObj"])["models"];
      return models != null ? models.ToString() : "{}";
    }" />
    <set-variable name="monthlyQuota" value="@(((JObject)context.Variables["contractObj"])["monthlyQuota"]?.Value<int>() ?? 100000)" />

    <!-- ================================================================ -->
    <!-- STEP 3: Extract Requested Model + Validate via Models Map        -->
    <!--                                                                  -->
    <!-- The models map serves double duty: defines allowed models AND    -->
    <!-- their per-model TPM/PTU limits. If the model is not in the map, -->
    <!-- the request is denied (403).                                     -->
    <!-- ================================================================ -->
    <include-fragment fragment-id="set-llm-requested-model" />

    <!-- Look up per-model config from the models map -->
    <set-variable name="model-config" value="@{
      var models = JObject.Parse((string)context.Variables["contract-models"]);
      var requested = (string)context.Variables["requestedModel"];
      var config = models[requested];
      return config != null ? config.ToString() : "";
    }" />

    <!-- Reject if model not in contract's models map -->
    <choose>
      <when condition="@(string.IsNullOrEmpty((string)context.Variables["model-config"]))">
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>@{
            var models = JObject.Parse((string)context.Variables["contract-models"]);
            var allowed = string.Join(", ", models.Properties().Select(p => p.Name));
            return new JObject(
              new JProperty("error", new JObject(
                new JProperty("code", "ModelNotAuthorized"),
                new JProperty("message", $"Model '{context.Variables["requestedModel"]}' is not in your access contract. Allowed: {allowed}")
              ))
            ).ToString();
          }</set-body>
        </return-response>
      </when>
    </choose>

    <!-- Parse per-model TPM and PTU TPM from model config -->
    <set-variable name="modelTpm" value="@(JObject.Parse((string)context.Variables["model-config"])["tpm"]?.Value<int>() ?? 1000)" />
    <set-variable name="modelPtuTpm" value="@(JObject.Parse((string)context.Variables["model-config"])["ptuTpm"]?.Value<int>() ?? 0)" />

    <!-- ================================================================ -->
    <!-- STEP 4: Enforce Per-Model TPM + Monthly Quota (two limits)       -->
    <!--                                                                  -->
    <!-- Two independent llm-token-limit calls per request:               -->
    <!--                                                                  -->
    <!-- A) Per-model TPM: counter-key = "caller-name:model"               -->
    <!--    Hard 429 if this contract exceeds their TPM for THIS model.    -->
    <!--                                                                  -->
    <!-- B) Monthly quota: counter-key = "caller-name"                     -->
    <!--    Cost cap across all models. Uses a high TPM (10M) so it       -->
    <!--    only enforces the quota, not a per-minute rate.               -->
    <!--                                                                  -->
    <!-- NOTE: counter-key uses contract name (caller-name) so all        -->
    <!-- identities under one contract share the same quota counters.     -->
    <!--                                                                  -->
    <!-- NOTE: If tokens-per-minute doesn't accept policy expressions,    -->
    <!-- see "Policy 3: Tiered Fallback" below for a <choose> alternative.-->
    <!-- ================================================================ -->

    <!-- A) Per-model TPM limit (hard 429) -->
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"] + ":" + (string)context.Variables["requestedModel"])"
      tokens-per-minute="@((int)context.Variables["modelTpm"])"
      estimate-prompt-tokens="false"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />

    <!-- B) Monthly quota cost cap (across all models) -->
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="10000000"
      estimate-prompt-tokens="false"
      token-quota="@((int)context.Variables["monthlyQuota"])"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens-quota"
      remaining-tokens-header-name="remaining-tokens-quota" />

    <!-- ================================================================ -->
    <!-- STEP 5: Three-Priority PTU/Standard Routing with PTU Quota       -->
    <!--                                                                  -->
    <!-- Two independent controls determine if a request goes to PTU:     -->
    <!--                                                                  -->
    <!--   A) Priority routing (is this team allowed to use PTU?)         -->
    <!--      P1 → always PTU, P2 → PTU when <70% utilized, P3 → never   -->
    <!--                                                                  -->
    <!--   B) PTU TPM quota (has this team used up their PTU allocation?) -->
    <!--      ptuTpm = max TPM on PTU per model (soft cap)                 -->
    <!--      Tracked via APIM cache counter, reset every 60s (≈1 min)   -->
    <!--      When exceeded → overflow to PAYG pool (NOT 429)             -->
    <!--                                                                  -->
    <!-- Both A and B must allow PTU for the request to route there.      -->
    <!--                                                                  -->
    <!-- Backend pool naming:                                              -->
    <!--   Mixed pool:     {model}-pool      (PTU priority 1, PAYG priority 2) -->
    <!--   PAYG-only pool: {model}-payg-pool (P2 overflow, P3 economy)    -->
    <!-- ================================================================ -->

    <!-- PTU TPM from per-model config (already parsed in STEP 3) -->
    <!-- modelPtuTpm = 0 means no PTU access for this model -->

    <!-- Read cached PTU remaining capacity (set by outbound policy) -->
    <cache-lookup-value
      key="@("ptu-remaining:" + (string)context.Variables["requestedModel"])"
      variable-name="ptuRemainingCached"
      default-value="-1" />

    <!-- Read this team's PTU token consumption in the current window -->
    <cache-lookup-value
      key="@("ptu-consumed:" + (string)context.Variables["caller-name"] + ":" + (string)context.Variables["requestedModel"])"
      variable-name="ptuConsumedCached"
      default-value="0" />

    <set-variable name="ptuCapacity" value="@{
      // Total PTU capacity in tokens per minute for this model
      // TODO: Move to Named Value per model for configurability
      return 100000;
    }" />

    <set-variable name="ptuUtilization" value="@{
      var remaining = (string)context.Variables["ptuRemainingCached"];
      if (remaining == "-1") return 0.0; // No data yet → assume idle, allow P2
      var remainingTokens = double.Parse(remaining);
      var capacity = (int)context.Variables["ptuCapacity"];
      return capacity > 0 ? 1.0 - (remainingTokens / capacity) : 1.0;
    }" />

    <!-- Check if team has PTU quota remaining for this model (soft limit) -->
    <set-variable name="ptuQuotaAvailable" value="@{
      var ptuLimit = (int)context.Variables["modelPtuTpm"];
      if (ptuLimit <= 0) return false; // No PTU allocation for this model
      var consumed = int.Parse((string)context.Variables["ptuConsumedCached"]);
      return consumed < ptuLimit;
    }" />

    <!-- Threshold from Named Value (default 0.7 = 70%) -->
    <set-variable name="threshold" value="@{
      var t = "{{ptu-utilization-threshold}}";
      double val;
      return double.TryParse(t, out val) ? val : 0.5;
    }" />

    <!-- Build pool IDs from model name -->
    <!-- Dots stripped from model names in pool names -->
    <set-variable name="modelClean" value="@(((string)context.Variables["requestedModel"]).Replace(".", ""))" />
    <set-variable name="ptuPoolId" value="@((string)context.Variables["modelClean"] + "-pool")" />
    <set-variable name="stdPoolId" value="@((string)context.Variables["modelClean"] + "-payg-pool")" />

    <choose>
      <!-- ── P1: Route to mixed pool IF PTU quota available ──────────── -->
      <!-- Pool has PTU at priority=1, PAYG at priority=2.                -->
      <!-- If PTU quota exhausted → PAYG-only pool (soft overflow).       -->
      <!-- If PTU returns 429, pool's circuit breaker spills to PAYG.     -->
      <when condition="@((int)context.Variables["priority"] == 1)">
        <choose>
          <when condition="@((bool)context.Variables["ptuQuotaAvailable"])">
            <set-variable name="routeTarget" value="pool" />
            <set-backend-service backend-id="@((string)context.Variables["ptuPoolId"])" />
          </when>
          <otherwise>
            <!-- PTU quota exhausted → overflow to PAYG-only pool (still within total TPM) -->
            <set-variable name="routeTarget" value="payg-pool" />
            <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
          </otherwise>
        </choose>
      </when>

      <!-- ── P2: Mixed pool when utilization < threshold AND PTU quota available ── -->
      <when condition="@((int)context.Variables["priority"] == 2)">
        <choose>
          <when condition="@((bool)context.Variables["ptuQuotaAvailable"]
                             && (double)context.Variables["ptuUtilization"] < (double)context.Variables["threshold"])">
            <set-variable name="routeTarget" value="pool" />
            <set-backend-service backend-id="@((string)context.Variables["ptuPoolId"])" />
          </when>
          <otherwise>
            <set-variable name="routeTarget" value="payg-pool" />
            <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
          </otherwise>
        </choose>
      </when>

      <!-- ── P3: Always PAYG-only pool ────────────────────────────────── -->
      <otherwise>
        <set-variable name="routeTarget" value="payg-pool" />
        <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
      </otherwise>
    </choose>

    <!-- Set headers for logging / tracing -->
    <set-header name="X-Priority" exists-action="override">
      <value>@(context.Variables["priority"].ToString())</value>
    </set-header>
    <set-header name="X-Route-Target" exists-action="override">
      <value>@((string)context.Variables["routeTarget"])</value>
    </set-header>

    <!-- Backend auth: Managed Identity → Foundry -->
    <include-fragment fragment-id="set-backend-authorization" />

  </inbound>

  <backend>
    <base />
  </backend>

  <!-- ================================================================== -->
  <!-- OUTBOUND: Cache PTU Remaining Tokens for P2 Routing Decisions      -->
  <!--                                                                    -->
  <!-- Every response from a PTU backend includes:                        -->
  <!--   x-ratelimit-remaining-tokens: 45231                              -->
  <!--   x-ratelimit-remaining-requests: 87                               -->
  <!--                                                                    -->
  <!-- We cache this value (keyed by model) so the next P2 inbound        -->
  <!-- request can read it and decide PTU vs PAYG.                        -->
  <!--                                                                    -->
  <!-- Cache TTL = 60s aligns with PTU's 1-minute rate limit window.      -->
  <!-- ================================================================== -->
  <outbound>
    <base />

    <!-- Cache PTU remaining tokens (only when response came from PTU) -->
    <choose>
      <when condition="@(context.Response.Headers.ContainsKey("x-ratelimit-remaining-tokens")
                         && (string)context.Variables.GetValueOrDefault("routeTarget","") == "pool")">
        <!-- Cache global PTU remaining capacity (for P2 utilization decisions) -->
        <cache-store-value
          key="@("ptu-remaining:" + (string)context.Variables["requestedModel"])"
          value="@(context.Response.Headers.GetValueOrDefault("x-ratelimit-remaining-tokens", "0"))"
          duration="60" />

        <!-- Track this team's PTU consumption (for per-team PTU quota) -->
        <!-- Read current consumed value, add this request's tokens, write back -->
        <!-- TTL = 60s acts as automatic 1-minute window reset -->
        <cache-lookup-value
          key="@("ptu-consumed:" + (string)context.Variables["caller-name"] + ":" + (string)context.Variables["requestedModel"])"
          variable-name="prevPtuConsumed"
          default-value="0" />
        <cache-store-value
          key="@("ptu-consumed:" + (string)context.Variables["caller-name"] + ":" + (string)context.Variables["requestedModel"])"
          value="@{
            var prev = int.Parse((string)context.Variables["prevPtuConsumed"]);
            var consumed = int.Parse(context.Response.Headers.GetValueOrDefault("consumed-tokens",
                           context.Response.Headers.GetValueOrDefault("x-ratelimit-used-tokens", "0")));
            return (prev + consumed).ToString();
          }"
          duration="60" />
      </when>
    </choose>

    <!-- Emit usage tracking headers -->
    <set-header name="X-Caller-Name" exists-action="override">
      <value>@((string)context.Variables["caller-name"])</value>
    </set-header>
    <set-header name="X-Caller-Id" exists-action="override">
      <value>@((string)context.Variables["caller-id"])</value>
    </set-header>
    <set-header name="X-PTU-Utilization" exists-action="override">
      <value>@(((double)context.Variables["ptuUtilization"] * 100).ToString("F1") + "%")</value>
    </set-header>
    <set-header name="X-PTU-Consumed" exists-action="override">
      <value>@((string)context.Variables.GetValueOrDefault("ptuConsumedCached", "0"))</value>
    </set-header>
    <set-header name="X-PTU-Limit" exists-action="override">
      <value>@(context.Variables["modelPtuTpm"].ToString())</value>
    </set-header>
  </outbound>

  <!-- ================================================================== -->
  <!-- ON-ERROR: Emit diagnostics for throttling and routing failures      -->
  <!-- ================================================================== -->
  <on-error>
    <base />
    <choose>
      <when condition="@(context.Response.StatusCode == 429)">
        <!-- Log throttling event with app identity for alerting -->
        <trace source="priority-routing" severity="warning">
          <message>@{
            return $"429 Throttled: caller={context.Variables["caller-name"]}, " +
                   $"identity={context.Variables["caller-id"]}, " +
                   $"priority={context.Variables["priority"]}, " +
                   $"model={context.Variables["requestedModel"]}, " +
                   $"route={context.Variables.GetValueOrDefault("routeTarget","unknown")}";
          }</message>
        </trace>
      </when>
    </choose>
  </on-error>
</policies>
```

### Policy 2: Per-Model Token Limits (Removed — Now Default)

> **Note**: The previous "Policy 2: Per-Model Token Limits" variant has been removed. Policy 1 now **always** enforces per-model TPM limits via the `models` map — the old `subscription-level` vs `per-model` capacity mode choice is gone. Every contract defines per-model limits directly in the `models` array, and the policy uses `counter-key="caller-name:model"` for TPM enforcement.

### Policy 3: Tiered Fallback (If Dynamic TPM Expressions Not Supported)

If `tokens-per-minute` does **not** accept policy expressions (only static integers), use `<choose>` with hardcoded tiers. **Replace STEP 4** in Policy 1 with this:

```xml
<!-- ================================================================ -->
<!-- STEP 4 (fallback): Static TPM Tiers                              -->
<!--                                                                  -->
<!-- Use when llm-token-limit doesn't accept @() in tokens-per-minute.-->
<!-- Define 4-5 TPM tiers; contract specifies which tier.             -->
<!--                                                                  -->
<!-- Contract config adds "tpmTier": "high" | "medium" | "low" | ... -->
<!-- ================================================================ -->
<set-variable name="tpmTier" value="@(((JObject)context.Variables["contractObj"])["tpmTier"]?.Value<string>() ?? "low")" />

<choose>
  <!-- Tier: high (60K TPM, 5M monthly) — P1 production -->
  <when condition="@((string)context.Variables["tpmTier"] == "high")">
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="60000"
      estimate-prompt-tokens="false"
      token-quota="5000000"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />
  </when>

  <!-- Tier: medium (20K TPM, 1M monthly) — P2 standard -->
  <when condition="@((string)context.Variables["tpmTier"] == "medium")">
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="20000"
      estimate-prompt-tokens="false"
      token-quota="1000000"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />
  </when>

  <!-- Tier: low (5K TPM, 200K monthly) — P3 economy -->
  <when condition="@((string)context.Variables["tpmTier"] == "low")">
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="5000"
      estimate-prompt-tokens="false"
      token-quota="200000"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />
  </when>

  <!-- Tier: unlimited (no rate limit, quota only) — internal platform -->
  <when condition="@((string)context.Variables["tpmTier"] == "unlimited")">
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="1000000"
      estimate-prompt-tokens="false"
      token-quota="50000000"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />
  </when>

  <!-- Default: minimal access -->
  <otherwise>
    <llm-token-limit
      counter-key="@((string)context.Variables["caller-name"])"
      tokens-per-minute="1000"
      estimate-prompt-tokens="false"
      token-quota="50000"
      token-quota-period="Monthly"
      tokens-consumed-header-name="consumed-tokens"
      remaining-tokens-header-name="remaining-tokens"
      retry-after-header-name="retry-after" />
  </otherwise>
</choose>
```

### Policy Fragment: `set-llm-requested-model` (Citadel, for Reference)

This Citadel fragment extracts the model name from the request (URL path or body). Reused unchanged:

```xml
<!-- Fragment: set-llm-requested-model -->
<!-- Extracts model from URL path (/deployments/{model}/...) or request body -->
<fragment>
  <set-variable name="requestedModel" value="@{
    // Try URL path first: /openai/deployments/{model}/chat/completions
    var path = context.Request.Url.Path;
    var segments = path.Split('/');
    for (int i = 0; i < segments.Length - 1; i++) {
      if (segments[i] == "deployments" && i + 1 < segments.Length) {
        return segments[i + 1];
      }
    }
    // Fallback: model field in request body
    var body = context.Request.Body?.As<JObject>(preserveContent: true);
    return body?["model"]?.Value<string>() ?? "unknown";
  }" />
</fragment>
```

### Policy Fragment: `validate-model-access` (Legacy — Replaced by Models Map)

> **Note**: This fragment used a comma-separated `allowedModels` string variable. In the per-model refactor, model validation is done inline via the `contract-models` JObject lookup in STEP 3. This fragment is kept for reference only.

```xml
<!-- Fragment: validate-model-access (LEGACY — replaced by models map lookup) -->
<!-- Previously checked requestedModel against allowedModels variable -->
<fragment>
  <choose>
    <when condition="@{
      var allowed = ((string)context.Variables.GetValueOrDefault("allowedModels","")).Split(',');
      var requested = (string)context.Variables.GetValueOrDefault("requestedModel","unknown");
      // Empty allowedModels = all models allowed
      return allowed.Length > 0 && !string.IsNullOrEmpty(allowed[0]) && !allowed.Contains(requested);
    }">
      <return-response>
        <set-status code="401" reason="Unauthorized" />
        <set-header name="Content-Type" exists-action="override">
          <value>application/json</value>
        </set-header>
        <set-body>@{
          return new JObject(
            new JProperty("error", new JObject(
              new JProperty("code", "ModelNotAuthorized"),
              new JProperty("message", $"Access to model '{context.Variables["requestedModel"]}' is not permitted. Allowed models: {context.Variables["allowedModels"]}")
            ))
          ).ToString();
        }</set-body>
      </return-response>
    </when>
  </choose>
</fragment>
```

---

## Contract Configuration Storage

Contracts are stored in **Azure Blob Storage** (not APIM Named Values) because Named Values have a 4096-character limit that is easily exceeded with multiple teams. APIM fetches the blob via managed identity and caches the raw JSON string internally for 5 minutes (`cache-store-value duration="300"`). The blob is uploaded by a deployment script during Bicep deployment.

Note that `models` is an **object (map)** in the compiled form — not an array — for O(1) lookup by model name in the policy. The compile script converts the array form from contract files to this map form:

```json
{
  "contracts": {
    "Team A Production": {
      "name": "Team A Production",
      "priority": 1,
      "models": {
        "gpt-52-chat": { "tpm": 8000, "ptuTpm": 4000 },
        "text-embedding-3-large": { "tpm": 20000, "ptuTpm": 0 }
      },
      "monthlyQuota": 4000000,
      "environment": "PROD",
      "identities": [
        { "value": "a1b2c3d4-e5f6-7890-abcd-ef1234567890", "displayName": "Team A Production App", "claimName": "azp" },
        { "value": "/subscriptions/aaaa-bbbb-cccc/resourceGroups/team-a-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/team-a-mi", "displayName": "Team A Managed Identity", "claimName": "xms_mirid" }
      ]
    },
    "Team B Development": {
      "name": "Team B Development",
      "priority": 2,
      "models": {
        "gpt-52-chat": { "tpm": 20000, "ptuTpm": 10000 }
      },
      "monthlyQuota": 1000000,
      "environment": "DEV",
      "identities": [
        { "value": "b2c3d4e5-f6a7-8901-bcde-f12345678901", "displayName": "Team B Dev App", "claimName": "azp" }
      ]
    },
    "Team C Batch Processing": {
      "name": "Team C Batch Processing",
      "priority": 3,
      "models": {
        "gpt-52-chat": { "tpm": 5000, "ptuTpm": 0 },
        "text-embedding-3-large": { "tpm": 5000, "ptuTpm": 0 }
      },
      "monthlyQuota": 200000,
      "environment": "PROD",
      "identities": []
    }
  },
  "identities": [
    { "value": "a1b2c3d4-e5f6-7890-abcd-ef1234567890", "claimName": "azp", "displayName": "Team A Production App", "contract": "Team A Production" },
    { "value": "/subscriptions/aaaa-bbbb-cccc/resourceGroups/team-a-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/team-a-mi", "claimName": "xms_mirid", "displayName": "Team A Managed Identity", "contract": "Team A Production" },
    { "value": "b2c3d4e5-f6a7-8901-bcde-f12345678901", "claimName": "azp", "displayName": "Team B Dev App", "contract": "Team B Development" }
  ]
}
```

> **Reading the config**: The `identities` array is a **flat lookup table** compiled from all contracts. The policy iterates it to find a prefix match against the caller's JWT claims, then looks up the contract by name from the `contracts` map. This is O(N) where N is total identities across all contracts — typically small (<100). Team A has two identities (app registration + managed identity) that both resolve to the same contract, sharing quota. Team C has empty identities (contract exists but no callers mapped yet).

### Required Named Values

| Named Value ID | Example Value | Purpose |
|---|---|---|
| `ptu-utilization-threshold` | `0.5` | P2 routing threshold (0.0-1.0) |

> **Note**: `tenant-id` and `api-audience` (`https://cognitiveservices.azure.com`) are replaced at deploy time by Bicep — they are not runtime Named Values. `contracts-blob-url` is also injected at deploy time by Bicep and points to the blob storage URL containing the compiled contracts JSON.

### Scaling

Azure Blob Storage supports unlimited contract size, so there is no practical limit on the number of teams. APIM caches the blob internally for 5 minutes, so the blob is fetched at most once per 5-minute window per gateway instance.

---

## Backend Pool Configuration

### What Citadel Creates Automatically

The Citadel `llm-backend-onboarding` Bicep module **automatically creates backend pools grouped by model name**. The flow is:

```
foundryInstances array
  │
  ▼
llm-backends.bicep
  │ Creates one APIM Backend resource per Foundry instance
  │ Each backend has: endpoint URL, circuit breaker (429 + 500-503), managed identity auth
  │
  ▼
llm-backend-pools.bicep
  │ Groups backends by supported model name (flattens supportedModels across all backends)
  │ Creates a Pool ONLY when 2+ backends serve the same model
  │ Single-backend models → direct routing (no pool needed)
  │
  ▼
llm-policy-fragments.bicep
  │ Generates APIM policy fragments:
  │   - set-backend-pools:        JArray of { poolName, poolType, supportedModels }
  │   - set-target-backend-pool:  Looks up requestedModel → routes to pool or direct backend
  │   - set-backend-authorization: Sets managed identity auth per backend type
  │   - set-llm-requested-model:  Extracts model from URL path or request body
  │   - get-available-models:     Returns model deployment list (discovery endpoint)
```

**Key behavior**: The pool creation is **per model, not per Foundry instance**. If `gpt-52-chat` exists on 3 Foundry instances, one pool is created with all 3 backends, using `priority` and `weight` for routing.

### Example: What Gets Created

With per-deployment PTU configuration, each Foundry instance declares its deployments with an `isPtu` flag. The system creates per-model pools automatically — a `{model}-pool` (mixed pool: PTU backends at priority 1, PAYG backends at priority 2) and a `{model}-payg-pool` (PAYG-only):

```bicep
param foundryInstances = [
  {
    name: 'foundry-eastus'
    endpoint: 'https://foundry-eastus.services.ai.azure.com'
    deployments: [
      { modelName: 'gpt-52-chat', deploymentName: 'gpt-52-chat-ptu', isPtu: true }
      { modelName: 'gpt-52-chat', deploymentName: 'gpt-52-chat', isPtu: false }
      { modelName: 'text-embedding-3-large', deploymentName: 'text-embedding-3-large', isPtu: false }
    ]
  }

  {
    name: 'foundry-westus'
    endpoint: 'https://foundry-westus.services.ai.azure.com'
    deployments: [
      { modelName: 'gpt-52-chat', deploymentName: 'gpt-52-chat', isPtu: false }
    ]
  }

  {
    name: 'foundry-northeu'
    endpoint: 'https://foundry-northeu.services.ai.azure.com'
    deployments: [
      { modelName: 'gpt-52-chat', deploymentName: 'gpt-52-chat', isPtu: false }
    ]
  }
]
```

The system auto-creates per-model pools:

| APIM Resource | Type | Contents | Routing Role |
|---|---|---|---|
| `foundry-eastus` | Backend | East US endpoint (PTU + standard deploys) | — |
| `foundry-westus` | Backend | West US endpoint (standard deploys) | — |
| `foundry-northeu` | Backend | North EU endpoint (standard deploys) | — |
| **`gpt52chat-pool`** | Pool | PTU backends (priority 1) + PAYG backends (priority 2). Circuit breaker on 429. | **P1 always, P2 when PTU < 50%** |
| **`gpt52chat-payg-pool`** | Pool | PAYG backends only | **P2 overflow, P3 economy always** |
| `text-embedding-3-large` | Direct | → `foundry-eastus` | All priorities (no PTU) |

**Pool naming**: Per-deployment `isPtu` flags create two pools per model. The policy maps priorities to the right pool:

```
P1  →  set-backend-service: gpt52chat-pool        (mixed pool: PTU first, PAYG spillover on 429)
P2  →  check utilization:
         < 50%  →  gpt52chat-pool                  (use PTU idle capacity)
         ≥ 50%  →  gpt52chat-payg-pool              (PAYG-only pool, protect PTU for P1)
P3  →  set-backend-service: gpt52chat-payg-pool    (PAYG-only pool, always)
```

### Simplified Routing Policy (with PTU Quota)

With per-deployment pools, the policy constructs backend IDs from the model name. The PTU quota check is integrated — teams exceeding their per-model `ptuTpm` overflow to the PAYG-only pool:

```xml
<!-- ================================================================ -->
<!-- STEP 5: Three-Priority Routing with 2-Pool Design + Quota         -->
<!--                                                                   -->
<!-- Backend pool naming:                                               -->
<!--   Mixed pool:     {model}-pool      (PTU priority 1, PAYG priority 2) -->
<!--   PAYG-only pool: {model}-payg-pool (P2 overflow, P3 economy)    -->
<!--                                                                   -->
<!-- The policy checks BOTH priority AND PTU quota before routing      -->
<!-- to the mixed pool. PTU quota exceeded → soft overflow to PAYG.    -->
<!-- ================================================================ -->

<!-- PTU TPM from per-model config (already parsed in STEP 3) -->
<!-- modelPtuTpm = 0 means no PTU access for this model -->

<!-- Read cached PTU remaining capacity (global) -->
<cache-lookup-value
  key="@("ptu-remaining:" + (string)context.Variables["requestedModel"])"
  variable-name="ptuRemainingCached"
  default-value="-1" />

<!-- Read this team's PTU consumption in current window -->
<cache-lookup-value
  key="@("ptu-consumed:" + (string)context.Variables["caller-name"] + ":" + (string)context.Variables["requestedModel"])"
  variable-name="ptuConsumedCached"
  default-value="0" />

<set-variable name="ptuUtilization" value="@{
  var remaining = (string)context.Variables["ptuRemainingCached"];
  if (remaining == "-1") return 0.0; // No data → assume idle
  var remainingTokens = double.Parse(remaining);
  var capacity = 100000; // TODO: move to Named Value per model
  return capacity > 0 ? 1.0 - (remainingTokens / capacity) : 1.0;
}" />

<set-variable name="ptuQuotaAvailable" value="@{
  var ptuLimit = (int)context.Variables["modelPtuTpm"];
  if (ptuLimit <= 0) return false;
  var consumed = int.Parse((string)context.Variables["ptuConsumedCached"]);
  return consumed < ptuLimit;
}" />

<set-variable name="threshold" value="@{
  var t = "{{ptu-utilization-threshold}}";
  double val;
  return double.TryParse(t, out val) ? val : 0.5;
}" />

<!-- Build pool names from model name -->
<set-variable name="modelClean" value="@(((string)context.Variables["requestedModel"]).Replace(".", ""))" />
<set-variable name="ptuPoolId" value="@((string)context.Variables["modelClean"] + "-pool")" />
<set-variable name="stdPoolId" value="@((string)context.Variables["modelClean"] + "-payg-pool")" />

<choose>
  <!-- P1: Mixed pool if PTU quota available, else PAYG-only overflow -->
  <when condition="@((int)context.Variables["priority"] == 1)">
    <choose>
      <when condition="@((bool)context.Variables["ptuQuotaAvailable"])">
        <set-variable name="routeTarget" value="pool" />
        <set-backend-service backend-id="@((string)context.Variables["ptuPoolId"])" />
      </when>
      <otherwise>
        <set-variable name="routeTarget" value="payg-pool" />
        <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
      </otherwise>
    </choose>
  </when>

  <!-- P2: Mixed pool when utilization < threshold AND PTU quota available -->
  <when condition="@((int)context.Variables["priority"] == 2)">
    <choose>
      <when condition="@((bool)context.Variables["ptuQuotaAvailable"]
                         && (double)context.Variables["ptuUtilization"] < (double)context.Variables["threshold"])">
        <set-variable name="routeTarget" value="pool" />
        <set-backend-service backend-id="@((string)context.Variables["ptuPoolId"])" />
      </when>
      <otherwise>
        <set-variable name="routeTarget" value="payg-pool" />
        <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
      </otherwise>
    </choose>
  </when>

  <!-- P3: Always PAYG-only pool -->
  <otherwise>
    <set-variable name="routeTarget" value="payg-pool" />
    <set-backend-service backend-id="@((string)context.Variables["stdPoolId"])" />
  </otherwise>
</choose>
```

> **Note**: Models without PTU deployments (like `text-embedding-3-large`) only have a `{model}-payg-pool`, no mixed `{model}-pool` variant. For non-PTU models, omit `ptuTpm` (or set to 0) in the model config — the policy will always route to the PAYG-only pool.

### What About the Actual Deployment Name?

The `deploymentName` in the Foundry instance config identifies the actual deployment. The `set-backend-authorization` fragment and the actual request forwarded to Foundry use the **real deployment name** (e.g., `gpt-52-chat` or `gpt-52-chat-ptu`). The URL path `/openai/deployments/gpt-52-chat/chat/completions` is unchanged — APIM just routes the HTTP request to the correct backend endpoint based on which pool was selected.

### Required Named Values for Backend Routing

| Named Value ID | Example Value | Purpose |
|---|---|---|
| `ptu-utilization-threshold` | `0.5` | P2 routing threshold (0.0-1.0) |
| `ptu-models` | `gpt-52-chat,gpt-4o` | (Optional) Models that have PTU pools — for policy to skip PTU routing on non-PTU models |

---

## PTU Priority Interaction

### How Per-Model TPM Limits Interact with PTU Routing

Each team has **three controls** per model plus **priority routing** — independent mechanisms working together:

```
                   ┌─────────────────────┐
                   │  llm-token-limit #1 │     ┌──────────────────────────┐
                   │  (per-model TPM:    │     │  PTU Cache Counter       │
                   │   hard 429)         │     │  (per-model PTU quota:   │
                   │                     │     │   soft cap)              │
                   │  llm-token-limit #2 │     └────────┬─────────────────┘
                   │  (monthly quota:    │              │
                   │   cost cap)         │              │ read
                   └────────┬────────────┘              │
                            │                           ▼
                            ▼                     PTU allocation OK?
                     Per-model TPM OK?            gpt-52-chat: 4K ptuTpm
                     gpt-52-chat: 8K TPM                │
                            │                           │
                            │ yes                       │
                            ▼                           ▼
                   ┌────────────────────────────────────────────┐
                   │          Priority Routing Decision          │
                   │                                            │
                   │  P1: PTU pool IF ptuQuotaAvailable          │
                   │      else → PAYG (soft overflow)            │
                   │  P2: PTU pool IF ptuQuotaAvailable           │
                   │      AND utilization < 50%                   │
                   │      else → PAYG                             │
                   │  P3: Always → PAYG                           │
                   └────────────────────┬──────────────┬────────┘
                                        │              │
                                  {model}-pool    {model}-payg-pool
                                        │              │
                                  ┌─────▼──────┐ ┌─────▼──────┐
                                  │ Foundry    │ │ Foundry    │
                                  │ PTU        │ │ PAYG       │
                                  └─────┬──────┘ └────────────┘
                                        │
                               outbound: update both
                               ptu-remaining (global)
                               ptu-consumed (per-contract:model)
```

**Example: Team A (P1, gpt-52-chat: 8K TPM / 4K PTU)**

```
Request 1:  Total counter: 0/8K ✓    PTU counter: 0/4K ✓    → PTU pool  (✅ PTU)
Request 2:  Total counter: 2K/8K ✓   PTU counter: 2K/4K ✓   → PTU pool  (✅ PTU)
Request 3:  Total counter: 4K/8K ✓   PTU counter: 4K/4K ✗   → standard pool (⚡ PTU quota soft overflow)
Request 4:  Total counter: 6K/8K ✓   PTU counter: 4K/4K ✗   → standard pool (⚡ PTU quota soft overflow)
Request 5:  Total counter: 8K/8K ✗   →  429 (🛑 Total hard limit exceeded)
... 60 seconds later, cache counter resets ...
Request 6:  Total counter: 0/8K ✓    PTU counter: 0/4K ✓    → PTU pool  (✅ new window)
```

**Three independent controls:**
1. **Per-model TPM limit** (`models[model].tpm: 8000`) — hard cap via `llm-token-limit` #1 (counter-key=`caller-name:model`), 429 if exceeded
2. **Per-model PTU TPM quota** (`models[model].ptuTpm: 4000`) — soft cap via APIM cache counter, overflow → standard pool
3. **Priority routing** — determines eligibility for PTU (P1/P2 yes, P3 no) + utilization check for P2
4. **Monthly quota** (`monthlyQuota: 4000000`) — cost cap via `llm-token-limit` #2 (counter-key=`caller-name`), 429 if exceeded

### Oversubscription Scenarios

| Scenario | Team A (P1) | Team B (P2) | PTU Used By | PTU Utilization |
|---|---|---|---|---|
| **Normal** | 3K PTU + 1K PAYG = 4K total | 8K PTU = 8K total | A(3K) + B(8K) = 11K | ~11% of 100K |
| **Team A bursting** | 4K PTU + 4K PAYG = 8K total | 10K PTU = 10K total | A(4K) + B(10K) = 14K | ~14% |
| **Team A at PTU cap** | 4K PTU + 4K PAYG = 8K total | PTU<70% → 10K PTU | A(4K) + B(10K) = 14K | PTU capped per team |
| **PTU busy (>70%)** | 4K PTU + 4K PAYG = 8K total | B→PAYG (utilization high) | A(4K) only on PTU | P2 diverted to protect P1 |
| **Both at PTU cap** | 4K PTU cap hit → PAYG overflow | 10K PTU cap hit → PAYG overflow | A(4K) + B(10K) = 14K | Controlled by caps |

### Why Per-Model Limits Are Better Than Flat Limits

| Approach | Problem |
|---|---|
| **Single total limit only** | P1 team could consume all PTU capacity with no cap — other P1 teams starved. No model-level granularity. |
| **Single PTU limit only** | No control over total spend — team could consume unlimited PAYG |
| **Per-model TPM + PTU + monthly quota (this design)** | Per-model TPM gives fine-grained rate control; per-model PTU quota governs shared PTU capacity; monthly quota caps total cost across all models |

**Key insight**: The per-model PTU quota (`ptuTpm`) is a **governance control** — it answers "how much of our shared PTU capacity does this team get for this model?" The per-model TPM (`tpm`) is a **rate control** — it answers "how fast can this team consume tokens on this model?" The monthly quota (`monthlyQuota`) is a **cost control** — it answers "how much can this team spend total?"

### PTU Quota Cache Counter: Design Notes

The PTU quota is tracked via APIM's internal cache, not `llm-token-limit`:

| Aspect | `llm-token-limit` #1 (per-model TPM) | `llm-token-limit` #2 (monthly quota) | Cache counter (per-model PTU quota) |
|---|---|---|---|
| **Where enforced** | Inbound (before backend call) | Inbound (before backend call) | Inbound check + outbound update |
| **What it tracks** | Tokens per minute per model | Total tokens per month (all models) | Actual tokens consumed on PTU per model |
| **On exceed** | 429 to client (hard reject) | 429 to client (hard reject) | Route to PAYG (soft redirect) |
| **Counter key** | `caller-name:model` | `caller-name` | `ptu-consumed:{caller-name}:{model}` (cache key) |
| **Counter reset** | Built-in 1-minute sliding window | Monthly period | Cache TTL = 60s (approximate 1-minute window) |

> **Why not use a second `llm-token-limit` for PTU?** Because `llm-token-limit` returns 429 on exceed — we want soft redirect to PAYG, not rejection. There's no "check-only" mode for `llm-token-limit`.

> **Cache TTL approximation**: The 60s cache TTL acts as a rough 1-minute window. It's not a perfect sliding window (more like a tumbling window that resets whenever the cache entry expires), but it's good enough for quota governance — the total `llm-token-limit` provides the precise hard cap.

---

## Deployment Pipeline

### Step 1: Backend Onboarding (Citadel module — unchanged)

```bash
# Deploy backends and pools to APIM
az deployment sub create \
  --location eastus \
  --template-file bicep/infra/llm-backend-onboarding/main.bicep \
  --parameters bicep/infra/llm-backend-onboarding/main.bicepparam
```

### Step 2: Compile Access Contracts → Blob Storage

A build script reads all contract JSON files and compiles them into a single JSON blob uploaded to Azure Blob Storage. The Bicep deployment handles this via a deployment script:

```bash
# contracts/
#   team-a-prod.json
#   team-b-dev.json
#   team-c-batch.json

# Build script: compile-contracts.sh
python3 scripts/compile-contracts.py \
  --contracts-dir contracts/ \
  --output access-contracts-compiled.json

# Upload to Blob Storage (handled by Bicep deployment script)
az storage blob upload \
  --account-name $STORAGE_ACCOUNT \
  --container-name contracts \
  --name access-contracts.json \
  --file access-contracts-compiled.json \
  --auth-mode login \
  --overwrite
```

### Step 3: Deploy API Policy

```bash
# Deploy the single API-level policy
az apim api policy create \
  --resource-group $RG \
  --service-name $APIM_NAME \
  --api-id universal-llm-api \
  --value @policies/jwt-access-contract-policy.xml \
  --format rawxml
```

### Onboarding a New Team

1. Create a new `contracts/team-d-staging.json` with the schema above
2. Register an Entra ID app registration (or use existing one) and add its identity to the identities array
3. Run the compile script → Bicep deployment uploads to Blob Storage
4. **No APIM Products, Subscriptions, or policy changes needed**

```
New team request → Create JSON → PR review → CI/CD → Blob Storage updated → Done
```

---

## Foundry Integration

### How Teams Connect to Foundry Through APIM

Since we're not using APIM subscription keys, Foundry projects connect differently:

| Citadel (Original) | JWT Citadel (This Plan) |
|---|---|
| Foundry Connection stores APIM subscription key | Foundry Connection uses Entra ID token |
| `auth: { type: "ApiKey", credentials: { key: subscriptionKey } }` | `auth: { type: "AAD", credentials: { ... } }` |

Each Foundry project that needs APIM access:
1. Has an Entra ID app registration (service principal)
2. The app registration's `appid` (or managed identity's resource ID) is in the access contract identities array
3. Foundry agent calls APIM with `Authorization: Bearer <token>` 
4. APIM validates JWT, looks up contract, enforces limits

### Foundry Connection Configuration (Entra ID)

```bicep
// Foundry connection pointing to APIM — using Entra ID auth
resource foundryConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-10-01' = {
  name: '${projectName}/apim-llm-gateway'
  properties: {
    category: 'AzureOpenAI'
    target: '${apimGatewayUrl}/openai'
    authType: 'AAD'
    // No credentials needed — Foundry uses its managed identity
    // The managed identity's identity must be in the access contracts identities array
  }
}
```

---

## Clock Alignment: Three Unsynchronized Windows

A key design consideration is that **three independent time windows** govern token counting, and none of them are synchronized:

```
Azure OpenAI PTU                    APIM llm-token-limit              APIM Cache (PTU heuristic)
┌──────────────────┐                ┌──────────────────┐              ┌──────────────────┐
│  Fixed 1-min     │                │  Sliding 1-min   │              │  60s TTL from     │
│  window (server) │                │  window (APIM)   │              │  last PTU response│
│                  │                │                  │              │                   │
│  Resets on its   │                │  Independent     │              │  Refreshed each   │
│  own clock       │                │  per counter-key │              │  PTU response     │
└────────┬─────────┘                └────────┬─────────┘              └─────────┬─────────┘
         │                                   │                                  │
         │  x-ratelimit-remaining-tokens     │  429 when tpm exceeded           │  Feeds P2 routing
         │  (real-time PTU capacity signal)   │  (hard enforcement)              │  (best-effort hint)
         ▼                                   ▼                                  ▼
    PTU deployment                     Per-model TPM cap              "Should P2 use PTU?"
    knows its own limit                per team (hard 429)            utilization estimate
```

### Why they can't be aligned

- **Azure OpenAI's window** is internal to the PTU deployment — APIM has no visibility into when it resets.
- **`llm-token-limit`** uses APIM's own sliding window that starts independently per counter-key.
- **The cache TTL** starts from the timestamp of the last PTU response, not from any window boundary.

### Why this is fine

The three mechanisms serve **different purposes** and don't need to agree:

| Mechanism | Purpose | Precision needed |
|---|---|---|
| `llm-token-limit` (per-model TPM) | **Hard cap** — prevent a team from exceeding their per-model allocation | High (APIM handles this accurately within its own window) |
| `llm-token-limit` (monthly quota) | **Cost cap** — aggregate spending across all models | Low (monthly granularity) |
| Cache `ptu-remaining:{model}` | **Routing hint** — steer P2 away from PTU when it's busy | Low (directional signal, not enforcement) |
| PTU backend 429 | **Physical limit** — PTU itself rejects when truly full | Exact (server-side) |

The cache-based PTU utilization is a **best-effort heuristic**. Under steady traffic it's refreshed every response and stays reasonably accurate. Under bursty traffic or after idle periods, it can be stale — but the consequences are mild:

- **Stale-high** (cache says busy, PTU is actually idle): P2 goes to PAYG unnecessarily. Wastes some PAYG cost but no correctness issue.
- **Stale-low** (cache says idle, PTU is actually busy): P2 gets sent to PTU, may compete with P1 briefly. The PTU backend itself handles contention via its own 429s, and `llm-token-limit` still enforces the team's hard cap.

The real safety net is always the hard enforcement layers (`llm-token-limit` + PTU backend 429). The cache is just an optimization to reduce unnecessary PTU contention.

---

## Comparison: Citadel vs JWT Citadel

| Aspect | Citadel (Original) | JWT Citadel (This Plan) |
|---|---|---|
| **Team identity** | APIM Subscription Key | JWT claims with multi-identity support (azp, appid, xms_mirid, oid, sub) — prefix matching allows matching managed identities by subscription/resource group |
| **Rate limit counter** | `context.Subscription.Id` | Contract name (`caller-name`) — all identities under one contract share quota |
| **TPM enforcement** | Single total limit | Per-model TPM (hard 429) + general monthly quota (cost cap) + per-model PTU TPM (soft → PAYG) |
| **Policy scope** | Product-level (per product XML) | API-level (single policy, `<choose>` on claims) |
| **Priority routing** | None (all teams same backend pool) | 3-tier: P1→PTU (with quota), P2→PTU/PAYG dynamic, P3→PAYG |
| **PTU utilization awareness** | None | `x-ratelimit-remaining-tokens` cached per model |
| **PTU per-team governance** | None | Cache-based PTU consumption counter per `caller-name:model` |
| **Onboarding** | JSON → Bicep → APIM Product + Sub + Policy | JSON → compile → Blob Storage update (via Bicep deployment) |
| **Infrastructure per team** | APIM Product + Subscription + KV secrets | Nothing (just a JSON entry) |
| **Backend pools** | Same | Extended: per-model PTU pools + standard pools |
| **Model access** | `set-variable` in product policy | Contract config lookup |
| **Deployment complexity** | Bicep per contract | Single Blob Storage update (via Bicep deployment) |
| **Foundry integration** | APIM subscription key in connection | Entra ID auth in connection |
| **Scalability** | Unlimited (1 Product per team) | Unlimited (Blob Storage, APIM-cached) |
| **Policy complexity** | Simple (product-level isolation) | Higher (single policy with claim parsing + dual cache) |

---

## Implementation Checklist

- [ ] **Phase 1: Foundation**
  - [ ] Create Entra ID app registrations for each team (one per app/environment)
  - [ ] Define API audience and configure token issuance
  - [ ] Deploy Foundry instances with model deployments (PTU + PAYG)
  - [ ] Grant APIM Managed Identity `Cognitive Services OpenAI User` on each Foundry

- [ ] **Phase 2: Backend Onboarding** (Citadel module, unchanged)
  - [ ] Configure `foundryInstances` with all Foundry instances and their deployments (PTU + standard)
  - [ ] Deploy backends, pools, and policy fragments via Bicep
  - [ ] Verify per-model standard pools for P3 routing (e.g., `gpt52chat-pool`)
  - [ ] Verify circuit breaker configuration (429 → trip → standard fallback in pool)

- [ ] **Phase 3: Access Contracts**
  - [ ] Create contract JSON files per team with priority (1/2/3)
  - [ ] Build `compile-contracts.py` script
  - [ ] Deploy compiled contracts to Blob Storage (via Bicep deployment script)
  - [ ] Create Named Value: `ptu-utilization-threshold`

- [ ] **Phase 4: APIM Policy**
  - [ ] Deploy Policy 1 (complete API-level policy with 3-priority routing)
  - [ ] Deploy Citadel fragments (`set-llm-requested-model`, `set-backend-authorization`)
  - [ ] **Validate**: `tokens-per-minute` accepts policy expressions (if not, use Policy 3 fallback)
  - [ ] Test P1: JWT → PTU → success
  - [ ] Test P2: JWT → PTU when idle → PAYG when busy (simulate load)
  - [ ] Test P3: JWT → PAYG always (verify never hits PTU)
  - [ ] Test 403: unknown identity (no matching entry in identities array), unauthorized model
  - [ ] Test 429: burst beyond TPM limit

- [ ] **Phase 5: Load Test and Tuning**
  - [ ] Simultaneous P1 + P2 traffic → verify P2 diverts to PAYG at 70% threshold
  - [ ] Adjust `ptu-utilization-threshold` based on observed patterns
  - [ ] Verify cache TTL (60s) aligns well with traffic patterns
  - [ ] Monitor: PTU utilization during P2 diversion — is the gap between threshold and 429 sufficient?

- [ ] **Phase 6: Monitoring and Alerting**
  - [ ] App Insights custom dimensions: caller-name, caller-id, model, priority, routeTarget, tokens consumed
  - [ ] Dashboard: per-team usage, PTU utilization, PAYG spillover rate by priority
  - [ ] Dashboard: P2 routing decisions (% PTU vs % PAYG)
  - [ ] Alerts: team approaching quota, PTU utilization sustained >90%, P1 hitting PAYG (spillover)

---

## Risks and Open Questions

| Risk | Impact | Mitigation |
|---|---|---|
| Blob Storage availability | Contracts unavailable if blob storage is down | APIM cache provides 5-min resilience; cached contracts continue to work until TTL expires |
| `llm-token-limit` dynamic TPM expressions | APIM may not support `@()` in `tokens-per-minute` attribute | Verify in test; fallback: Policy 3 (tiered `<choose>` with static values) |
| JWT claim parsing adds latency | ~1-2ms per request | Acceptable; `validate-jwt` already parses the token |
| Cache staleness for P2 routing | `x-ratelimit-remaining-tokens` reflects last PTU response, not real-time | 60s TTL + safety gap (30% buffer) mitigates. Worst case: one P2 request hits PTU during spike, gets 429 → retry to PAYG |
| PTU response doesn't include remaining-tokens header | Some Azure OpenAI deployments may not return this header | Fallback: treat as "unknown" → default P2 to PTU (optimistic). Add alert on missing header. |
| Multi-region APIM: counters and cache are per-gateway | Teams get 2x TPM and 2x PTU quota across 2 regions; cache not shared | Acceptable for most cases; document as known behavior. Use Redis external cache for cross-region sharing if needed. |
| Cold start: no cache data on first request | P2 routes to PTU (no utilization data); PTU consumed counter starts at 0 | By design — assume idle on cold start. Cache populates after first PTU response. |
| P1 burst exceeds 30% buffer | P1 suddenly uses 100% PTU; P2 still being sent to PTU during cache lag | Backend pool circuit breaker on 429 provides safety net — P2 gets 429 from PTU → pool routes to PAYG within the same request. |
| PTU quota cache counter accuracy | Cache TTL (60s) is a tumbling window, not sliding — can briefly allow 2× quota at boundary | Acceptable for governance — total `llm-token-limit` provides the hard cap. PTU quota is a soft allocation, not a billing control. |
| PTU consumed token source | `consumed-tokens` or `x-ratelimit-used-tokens` header may not be available | Fallback to 0 — PTU quota counter undercounts, allowing slightly more PTU than allocated. Total limit still enforced. |

### Critical Validation Needed

> ⚠️ **Must verify**: Does `llm-token-limit` accept policy expressions for `tokens-per-minute` and `token-quota` attributes?
>
> The [documentation](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy) confirms policy expressions are allowed for `counter-key`, but doesn't explicitly state the same for TPM/quota attributes.
>
> **If dynamic TPM is NOT supported**, use **Policy 3** (Tiered Fallback) which uses `<choose>` with static values per tier. This is equally effective — it just means teams pick from predefined tiers (high/medium/low/unlimited) rather than arbitrary TPM values.
>
> **Additional consideration**: The per-model refactor requires **two `llm-token-limit` calls per request** (one for per-model TPM, one for monthly quota). Verify this does not introduce unacceptable latency — each call involves a distributed counter check. If latency is a concern, the monthly quota call could be moved to outbound (post-facto accounting) at the cost of slightly less precise enforcement.

### `x-ratelimit-remaining-tokens` Header Availability

> ⚠️ **Must verify**: Does your Azure OpenAI / Foundry deployment return `x-ratelimit-remaining-tokens` in response headers?
>
> This header is standard for Azure OpenAI PTU deployments (since 2024), but:
> - **Foundry inference endpoints** may not return it (depends on the underlying deployment)
> - **PAYG deployments** may return it with different semantics (per-subscription limit, not per-deployment)
>
> **Fallback if header missing**: The policy treats missing header as "PTU idle" and routes P2 to PTU. This is safe — the backend pool's circuit breaker (429 → trip → PAYG) provides the safety net.

---

## References

- [Citadel Access Contracts (citadel-v1)](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/citadel-access-contracts)
- [Citadel LLM Backend Onboarding](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/llm-backend-onboarding)
- [APIM llm-token-limit policy](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
- [APIM validate-jwt policy](https://learn.microsoft.com/en-us/azure/api-management/validate-jwt-policy)
- [Architecture Plan (parent doc)](./architecture-plan.md)
