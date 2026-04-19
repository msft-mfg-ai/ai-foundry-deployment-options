# PTU Priority Routing — Design Risks & Limitations

> **Last updated:** March 2026 — reflects implementation of the two-API loopback architecture.
> Sections marked with ✅ Resolved are kept for historical context.

## Overview

This document captures known risks, limitations, and open questions in the PTU priority routing design. P2 ("PTU when idle") was abandoned — the production system uses only P1 (production → PTU) and P3 (economy → PAYG).

---

## 1. PTU Response Headers — Different from PAYG ✅ Resolved

PTU deployments return different rate-limit headers than PAYG (`azure-openai-deployment-utilization` instead of `x-ratelimit-remaining-tokens`). This affected the original P2 utilization-based routing design.

> **Resolution:** P2 was abandoned, eliminating the need for utilization-based routing. The two-API loopback uses `llm-token-limit` for PTU capacity enforcement — no response header parsing required.

---

## 2. Token Consumption Unknown at Request Time ✅ Resolved

Before sending a request to the backend, exact token consumption is unknown. The original design used custom token estimation (prompt chars/4 + max_tokens/2) for pre-debit counters.

> **Resolution:** `llm-token-limit` handles token estimation internally — it estimates on inbound and adjusts on outbound. All custom estimation logic was removed.

---

## 3. Cache Not Atomic — Race Conditions ✅ Resolved

APIM's `cache-lookup-value` / `cache-store-value` is not atomic — concurrent requests can read the same cached value, compute independently, and overwrite each other (lost update problem).

> **Resolution:** All custom cache counters were replaced by `llm-token-limit`. Additionally, APIM's cache was discovered to NOT use sliding windows — it uses fixed-interval expiry. This makes cache-based counters fundamentally unsuitable for matching PTU's 60-second sliding window. `llm-token-limit` uses proper sliding windows internally.

---

## 4. P2 Priority — Feasibility Assessment ✅ Resolved

P2 ("PTU when idle") routing was architecturally sound but operationally fragile: utilization signals lag, no pre-request token estimation, and race conditions with concurrent P2 requests all seeing low utilization simultaneously.

> **Resolution:** P2 was abandoned. The production system uses only P1 (production → PTU via two-API loopback with PAYG fallback) and P3 (economy → PAYG only). There is no "PTU when idle" tier — utilization tracking, stale cache reads, and dynamic routing decisions are all eliminated.

---

## 5. Deployment Naming Convention — Hard Requirement

### Why This Matters

APIM backend pools forward the **same URL path** to all backends in the pool:

```
POST /openai/deployments/{deployment-name}/chat/completions
```

Backends are registered per-**instance** (not per-deployment). The deployment name segment in the URL passes through to whichever backend the pool selects. **If any backend in the pool has a different deployment name, requests routed there will 404.**

### The Rule

> **Every Foundry instance that serves the same model MUST use the same deployment name, and that name MUST equal the `modelName` in the configuration.**

This applies across ALL instances — PTU and paygo, all regions:

```
✅ CORRECT — all instances use the same deployment name:

  Foundry-EastUS-PTU:     deployment "gpt-4.1-mini"
  Foundry-WestUS-PTU:     deployment "gpt-4.1-mini"
  Foundry-EastUS-Paygo:   deployment "gpt-4.1-mini"
  Foundry-WestUS-Paygo:   deployment "gpt-4.1-mini"

❌ WRONG — PTU uses a different name:

  Foundry-EastUS-PTU:     deployment "gpt-4.1-mini-ptu"    ← BREAKS routing
  Foundry-EastUS-Paygo:   deployment "gpt-4.1-mini"
```

### Enforcement

The Bicep type system enforces this by design:
- `foundryDeploymentType` has only `modelName` — there is **no `deploymentName` override** field
- The `modelName` value is what callers use in the URL and what each Azure OpenAI instance must have as its deployment name
- If you need to distinguish PTU from paygo deployments, use **separate Foundry instances** (not different deployment names on the same instance)

### Setup Checklist

When provisioning a new Azure OpenAI / Foundry instance:

1. Create the model deployment with the **canonical model name** (e.g., `gpt-4.1-mini`, `gpt-4o`)
2. Do NOT add suffixes like `-ptu`, `-prod`, `-v2` to the deployment name
3. If migrating existing instances with non-standard names, rename the deployment or create a new one with the correct name
4. Verify by calling the deployment directly:
   ```bash
   curl https://<instance>.openai.azure.com/openai/deployments/gpt-4.1-mini/chat/completions?api-version=2024-10-21 \
     -H "api-key: <key>" -H "Content-Type: application/json" \
     -d '{"messages":[{"role":"user","content":"hello"}]}'
   ```
5. The same URL path must return 200 on **every instance** that serves this model

### Foundry Instance Separation

Instances must be **PTU-only or paygo-only** — do not mix on the same instance:

| Guideline | Rationale |
|-----------|-----------|
| ✅ PTU-only instances (1 per region) | Billing clarity, capacity isolation, clean monitoring |
| ✅ Paygo-only instances (1+ per region) | Separate rate limits, independent scaling |
| ❌ Mixed PTU+paygo on same instance | Confusing billing, no capacity benefit, naming complications |

### What Happens If Names Don't Match

| Scenario | Result |
|----------|--------|
| PTU deployment named `gpt-4.1-mini-ptu`, URL has `gpt-4.1-mini` | **404 Not Found** from PTU backend |
| Paygo deployment named `gpt-41-mini` (missing dot), URL has `gpt-4.1-mini` | **404 Not Found** from paygo backend |
| One region has `gpt-4.1-mini`, another has `gpt-41-mini` | **Intermittent 404s** — depends on which backend the pool selects |

---

## 6. Multi-Region Topology — APIM + PTU + Paygo

### 6.1 Pool Design

Each model gets **two pools** (PTU-only and PAYG-only):

```
{model}-ptu-pool:      PTU backends only (for P1 routing via PTU Gate)
{model}-payg-pool:     PAYG backends only (for P2/P3 and P1 PAYG fallback)
```

> **Resolution:** Pools were further separated from the original mixed-pool design. Each model now gets PTU-only and PAYG-only pools — no mixed pools. The Priority API policy selects the correct pool based on the routing case, and the PTU Gate API always targets the PTU-only pool.

### 6.2 APIM Topology Options

**Option A: Single APIM Premium Multi-Region (Recommended)** — Single management plane with gateway units in each region. Policy selects regional pools via `context.Deployment.Region`. Cost: ~$2,800/mo base + ~$2,500/mo per additional region.

**Option B: Separate APIM Instances Per Region** — Full regional isolation with independent management planes. Higher cost and operational overhead. Use only when data residency or per-region SKU differences are required.

---

## 8. Token Estimation Policy Fragments ✅ Resolved

Two APIM policy fragments (`token-estimation-inbound.xml`, `token-estimation-outbound.xml`) implemented a pre-debit/reconcile pattern for custom PTU token tracking. The inbound fragment estimated tokens from request body size + max_tokens, and the outbound fragment reconciled with actual consumption.

> **Resolution:** Both fragments were superseded by `llm-token-limit` which handles estimation internally. **Note:** The files still exist in the repository (`modules/apim/advanced/token-estimation-{inbound,outbound}.xml`) as reference/prototypes — they are not used in the production policy.

---

## 9. Next Steps

- [ ] **Choose APIM topology**: Single Premium multi-region (recommended) vs. separate instances per region
- [ ] **Create region-specific pools in Bicep**: Refactor `multi-foundry-backends.bicep` to produce `{model}-{region}-pool` with regional PTU + PAYG tiers
- [ ] **Add `context.Deployment.Region` routing**: Policy selects the right regional pool based on which APIM gateway handles the request
- [ ] **Empirical PTU header test**: Deploy a real PTU deployment and capture all response headers
- [ ] **Document soft limit behavior**: Make it clear in contract docs that PTU quotas are approximate
- [ ] **Streaming support**: `context.Response.Body.As<JObject>` may not work for `stream: true` responses — need to handle chunked responses separately
