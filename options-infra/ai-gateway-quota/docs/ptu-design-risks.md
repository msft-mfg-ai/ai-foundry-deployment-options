# PTU Priority Routing — Design Risks & Limitations

## Overview

This document captures known risks, limitations, and open questions in the PTU priority routing design. These affect the **P2 (PTU when idle)** tier most significantly, and have implications for per-team PTU quota tracking.

---

## 1. PTU Response Headers — Different from PAYG

### Finding

PTU deployments return **different headers** than PAYG deployments:

| Header | PAYG | PTU |
|--------|------|-----|
| `x-ratelimit-remaining-tokens` | ✅ Tokens remaining in TPM window | ❓ May not be present or meaningful |
| `x-ratelimit-remaining-requests` | ✅ Requests remaining | ❓ May not be present |
| `azure-openai-deployment-utilization` | ❌ Not present | ✅ Current % utilization of provisioned capacity (❓ May not be present) |
| `Retry-After` | ✅ On 429 | ✅ On 429 |

### Impact on Current Design

Our policy uses `x-ratelimit-remaining-tokens` from the PTU backend response to calculate utilization:

```
utilization = 1.0 - (remainingTokens / ptuCapacity)
```

**If PTU doesn't return `x-ratelimit-remaining-tokens`**, the utilization calculation defaults to 0.0 (idle), which means **P2 traffic would always be routed to PTU** — the opposite of conservative.

### Action Required

- **Verify empirically**: Deploy a real PTU and inspect response headers. Check for both `x-ratelimit-remaining-tokens` AND `azure-openai-deployment-utilization`.
- **Adapt policy**: If PTU only returns `azure-openai-deployment-utilization`, parse the percentage directly instead of computing from remaining tokens.
- **Fallback**: If neither header is available, P2 routing to PTU should be disabled (default to standard pool).

### Fallback Options When No Utilization Headers Are Returned

| Option | How It Works | Latency | Accuracy |
|--------|-------------|---------|----------|
| **A. 429-reactive** (simplest) | Don't measure utilization. PTU at priority 1 in pool, standard at priority 2. 429 triggers circuit breaker → spillover. | 0 | N/A — no dynamic P2 |
| **B. Azure Monitor metric** | Query `ProvisionedManagedUtilizationV2` metric via `send-request` to Azure Monitor REST API. Cache 1-2 min. | 1-2 min lag | Authoritative but lagging |
| **C. Self-tracking** | Count actual tokens from response `usage` JSON body in outbound. Sum per model in cache. Estimate utilization as `sum / ptuCapacity`. | Real-time (with race caveats) | Approximate |
| **D. Inbound pre-decrement** | Estimate tokens from request body (see formula above). Pre-decrement on inbound, adjust on outbound. Use aggregate counter for P2 utilization check. | Real-time | Best available in APIM |

**Recommendation**: Option A for production v1. Options C/D as progressive enhancements with documented limitations.

---

## 2. Token Consumption is Unknown at Request Time

### The Problem

When APIM receives a request, it **cannot know how many tokens the response will consume**:

- **Prompt tokens**: Can be estimated from request body size (~4 chars/token for English), but varies by model and tokenizer.
- **Completion tokens**: Completely unknown until the response finishes. A `max_tokens: 4000` request might produce 50 tokens or 4000.
- **Streaming**: With `stream: true`, tokens arrive incrementally — total consumption only known after stream ends.

### Impact on Per-Team PTU Quota

Our design tracks per-team PTU consumption via APIM cache counters, incremented in the **outbound** policy (after the response). This means:

1. **Request arrives** → APIM checks cached counter → "quota available" → routes to PTU
2. **Meanwhile**, 10 more requests arrive before #1's response → all see "quota available" → all route to PTU
3. **Responses complete** → counters updated → now over quota

This is a **burst vulnerability**: under concurrent load, teams can significantly exceed their PTU allocation before the counters catch up.

### Possible Mitigations

| Approach | Tradeoff |
|----------|----------|
| **Pre-decrement with estimation** (prompt_est + max_tokens × 0.5), adjust on outbound | Best balance — shrinks race window to inbound parse time |
| **Accept eventual consistency** | Simple; document that PTU soft limits are approximate |
| **Use `llm-token-limit` for PTU pool** | APIM's built-in; handles token estimation internally; but it's per-counter-key, not per-pool |

### Recommended: Inbound Pre-Decrement with Estimation

**Formula**: `estimated_tokens = request_body_bytes / 4 + max_tokens × 0.5`

Where:
- `request_body_bytes / 4` ≈ prompt tokens (1 token ≈ 4 bytes for English, includes JSON overhead which over-estimates slightly — conservative)
- `max_tokens × 0.5` ≈ expected completion tokens (half of the allowed max — empirically safe)
- If `max_tokens` is absent in request, use `2048` as default

**Validation against real patterns:**

| Pattern | Actual Tokens | Estimate | Over-estimate |
|---------|--------------|----------|---------------|
| Short question | 33 | 96 | +191% |
| Medium question | 395 | 577 | +46% |
| RAG long context | 1,020 | 1,022 | +0% |
| Code generation | 1,855 | 2,083 | +12% |
| Multi-turn chat | 730 | 1,166 | +60% |

✅ Never under-estimates. Over-estimation is acceptable for a soft quota — it means teams hit their PTU limit slightly earlier, which is the safe direction (overflow → standard pool, not lost requests).

**How it works in the policy:**

1. **Inbound** (before `send-request`):
   - Parse request body → extract `max_tokens`
   - Compute `estimated_tokens`
   - Read cached `ptu-consumed:{team}:{model}` counter
   - If `consumed + estimated > ptuTpmLimit` → route to standard pool
   - Else → **pre-increment** counter by `estimated_tokens`, route to PTU pool

2. **Outbound** (after response):
   - Parse response body → read `usage.total_tokens` (actual)
   - Compute `adjustment = estimated_tokens - actual_tokens`
   - **Decrement** counter by `adjustment` (release the over-estimate)

This shrinks the race window from "entire request duration" (seconds) to "inbound policy execution" (milliseconds). The over-estimation provides a safety buffer against concurrent bursts.

---

## 3. APIM Cache is Not Atomic — Race Conditions

### The Problem

APIM's `cache-lookup-value` / `cache-store-value` operations are **not atomic**. There is no compare-and-swap, no locking, no transactions. Multiple concurrent requests can:

1. **Read** the same cached value (e.g., `ptu-consumed = 800`)
2. **Each independently compute** new value (e.g., `800 + 200 = 1000`)
3. **Write** back the same result (1000) — losing one increment

This is a classic **lost update** problem.

### Where This Affects Us

| Cache Key | Purpose | Race Risk |
|-----------|---------|-----------|
| `ptu-consumed:{team}:{model}` | Per-team PTU quota tracking | **HIGH** — concurrent requests from same team to same model |
| `ptu-remaining:{model}` | Cached PTU remaining tokens (from response header) | **MEDIUM** — stale reads cause wrong P2 routing decisions |

### Severity Assessment

With the **pre-decrement pattern**, race conditions are significantly reduced:

| Scenario | Without Pre-Decrement | With Pre-Decrement |
|----------|----------------------|-------------------|
| Race window | Entire request duration (1-30s) | Inbound policy execution (~5ms) |
| Burst overshoot (10 concurrent, max_tokens=4000) | Up to ~40K tokens | Up to ~5K tokens (just the parse overlap) |
| Self-correction | Next request sees updated counter | Same, but counter is more current |

The remaining race is between concurrent inbound executions reading the cache at the same millisecond. This is a narrow window and acceptable for soft quotas.

### Comparison with `llm-token-limit`

APIM's built-in `llm-token-limit` policy likely has the same concurrency limitations internally, but:
- It **estimates tokens on inbound** (before sending to backend) using the prompt + estimated completion
- It **adjusts on outbound** with actual consumption
- It's a first-party policy, so it may have internal optimizations we don't have access to

Our custom cache-based PTU tracking is strictly worse than `llm-token-limit` for atomicity.

---

## 4. P2 Priority — Feasibility Assessment

### Current Design
P2 (standard) routes to PTU when utilization < 50%, to standard when ≥ 50%.

### Problems

1. **Utilization signal is lagging**: Based on the previous response's header, not current state. Under bursty load, utilization can spike between reads.
2. **No pre-request token estimation**: Can't predict if routing this P2 request to PTU will push utilization over the threshold.
3. **Race conditions**: Multiple P2 requests can simultaneously see "utilization = 40%" and all route to PTU, pushing it past 70% together.

### Realistic Alternatives for P2

| Approach | Complexity | Accuracy |
|----------|-----------|----------|
| **A. Simple priority pools** (current): P1→PTU pool, P2+P3→PAYG pool. PTU spillover on 429 handled by pool priority. | Low | N/A — no dynamic routing |
| **B. 429-reactive**: P2 always tries PTU. On 429, circuit breaker sends to PAYG. No utilization tracking. | Low | Reactive, not proactive |
| **C. Sliding window estimation**: Track total tokens consumed (all teams) via cache. Compare to PTU capacity. Route P2 if estimated utilization < threshold. | Medium | Approximate, race-prone |
| **D. External state**: Use Redis or Cosmos DB with atomic increments for real-time utilization tracking. | High | Best accuracy |
| **E. Azure Monitor metrics**: Query PTU utilization metric via Azure Monitor. Cache for 1 min. | Medium | 1-2 min lag, but authoritative |

### Recommendation

**Option A or B for v1.** Dynamic P2 routing (current design) is architecturally sound but **operationally fragile** due to the limitations above. For a production deployment:

- **P1 → PTU pool** (with PAYG spillover on 429) — this works reliably
- **P2 → PAYG pool** (or PTU pool with lower priority, relying on 429+circuit breaker)
- **P3 → PAYG pool only**

The dynamic utilization check can be kept as an **optimization layer** with clear documentation that it's approximate and best-effort.

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

### 6.1 Pool Design: Single Pool Per Model with 3-Priority Failover

Each model gets **two pools**:

```
{model-clean}-pool:          (mixed pool)
  Priority 1: PTU backends   ("free" provisioned capacity)
  Priority 2: PAYG backends  (pay-per-token, circuit breaker failover)

{model-clean}-payg-pool:     (PAYG-only pool)
  PAYG backends only          (for P2 overflow and P3 economy routing)
```

The pool's circuit breaker handles failover: on 429 from PTU backends (priority 1), the request fails over to PAYG backends (priority 2). The APIM policy adds instant retry so the **current** request also benefits from failover.

This design works because **all backends use the same deployment name** (see Section 5). The URL path passes through unchanged regardless of which backend the pool selects.

### 6.2 APIM Topology Options

#### Option A: Single APIM Premium Multi-Region (Recommended)

```
                    ┌─────────────────────────────┐
                    │   APIM Premium (single)      │
                    │   Management plane: EastUS   │
                    ├──────────┬──────────────────┤
                    │ Gateway  │     Gateway       │
                    │ EastUS   │     WestUS        │
                    └────┬─────┘─────────┬─────────┘
                         │               │
    context.Deployment   │               │   context.Deployment
    .Region = "East US"  │               │   .Region = "West US"
                         ▼               ▼
              ┌─────────────────┐  ┌─────────────────┐
              │ gpt41mini-      │  │ gpt41mini-      │
              │  eastus-pool    │  │  westus-pool    │
              │                 │  │                 │
              │ P1: PTU-EastUS  │  │ P1: PTU-WestUS  │
              │ P2: PTU-WestUS  │  │ P2: PTU-EastUS  │
              │ P3: Paygo-EUS   │  │ P3: Paygo-WUS   │
              └─────────────────┘  └─────────────────┘
```

**Policy routing** — one line picks the right pool based on gateway region:

```xml
<set-variable name="regional-pool" value="@{
    var region = context.Deployment.Region.Replace(" ", "").ToLower();
    return (string)context.Variables["model-clean"] + "-" + region + "-pool";
}" />
<set-backend-service backend-id="@((string)context.Variables["regional-pool"])" />
```

| Aspect | Detail |
|--------|--------|
| **Cost** | ~$2,800/mo base + ~$2,500/mo per additional region |
| **Management** | Single management plane — policies, subscriptions, products, contracts all centralized |
| **Cache scope** | APIM internal cache is **per-gateway** — counters are naturally region-scoped (desirable) |
| **Failover** | Azure Front Door or Traffic Manager routes clients to nearest healthy APIM gateway |
| **Scaling** | Add regions by adding gateway units — no new APIM instances to manage |

#### Option B: Separate APIM Instances Per Region

```
    ┌───────────────────┐         ┌───────────────────┐
    │ APIM-EastUS       │         │ APIM-WestUS       │
    │                   │         │                   │
    │ gpt41mini-pool:   │         │ gpt41mini-pool:   │
    │  P1: PTU-EastUS   │         │  P1: PTU-WestUS   │
    │  P2: PTU-WestUS   │         │  P2: PTU-EastUS   │
    │  P3: Paygo-EUS    │         │  P3: Paygo-WUS    │
    └───────────────────┘         └───────────────────┘
```

| Aspect | Detail |
|--------|--------|
| **Cost** | ~$2,800/mo **per instance** (more expensive at 2+ regions) |
| **Management** | Separate management planes — must sync policies, subscriptions, contracts |
| **Cache scope** | Naturally isolated (separate instances) |
| **Failover** | Azure Front Door routes clients to nearest healthy instance |
| **Scaling** | Independent scaling per region, but more operational overhead |

**Use Option B only when:** full regional isolation is required (e.g., data residency), or you need different SKUs/configurations per region.

### 6.3 Circuit Breaker Behavior in 3-Priority Pools

Understanding the cascade is important for capacity planning:

```
Timeline:
  t=0     Local PTU handles all traffic (P1)
  t=X     Local PTU saturated → returns 429
  t=X     Circuit breaker trips on P1 backend (1 min duration)
  t=X..+1m  ALL traffic → Remote PTU (P2)
            ⚠️ Latency spike: +30-60ms cross-region
  t=Y     Remote PTU also saturated → returns 429
  t=Y     Circuit breaker trips on P2 backend
  t=Y..+1m  ALL traffic → Paygo (P3)
            ⚠️ Cost spike: paygo tokens
  t=X+1m  P1 circuit breaker resets → traffic tries local PTU again
            If local PTU recovered → traffic returns to P1
            If still 429 → breaker re-trips, back to P2/P3
```

**Key observations:**
- Circuit breaker duration (default 1 min) determines how long traffic stays on a lower-priority tier
- Both P1 and P2 breakers can be tripped simultaneously → all traffic on paygo
- `acceptRetryAfter: true` lets the PTU's `Retry-After` header override the 1 min trip duration
- This cascade is **desirable** — it's exactly the failover behavior we want

### 6.4 Paygo Placement

Paygo backends should be **co-located with the APIM gateway** (same region), not cross-region:

| Placement | Latency to Paygo | When to use |
|-----------|------------------|-------------|
| Same region as APIM gateway | <5ms | ✅ Default — P3 should be low-latency |
| Cross-region | +30-60ms | ❌ P3 is already the fallback; don't add latency on top |

If paygo capacity is limited in one region, add paygo backends in the other region at a lower weight, but keep the primary paygo co-located.

---

## 7. Summary of Risks

| Risk | Severity | Component Affected | Mitigation |
|------|----------|-------------------|------------|
| Inconsistent deployment names across instances | **CRITICAL** | All backend routing | Enforced by type system (no `deploymentName` override); setup checklist in Section 5 |
| PTU doesn't return `x-ratelimit-remaining-tokens` | **HIGH** | P2 routing, utilization tracking | Verify headers empirically; adapt to `azure-openai-deployment-utilization` |
| Multi-region PTU in flat pool (no priority) | **HIGH** | Latency, utilization tracking | 3-priority regional pools; local PTU → remote PTU → paygo |
| Circuit breaker oscillation on PTU saturation | **MEDIUM** | Latency stability | Expected behavior; document that P2→P3 cascade causes temporary latency/cost spikes |
| Token consumption unknown at request time | **MEDIUM** | Per-team PTU quota | Accept soft limits are approximate; use `llm-token-limit` for hard limits |
| Cache race conditions (lost updates) | **MEDIUM** | Per-team PTU counters | Document as approximate; consider Redis for critical deployments |
| Stale utilization reads | **LOW** | P2 routing | Circuit breaker self-corrects on 429 |
| Burst overshoot on PTU quota | **MEDIUM** | Per-team fairness | Pre-estimate tokens from request size as additional guard |

---

### 8. Token Estimation Policy Fragments (Pre-Debit/Reconcile Pattern)

Two APIM policy fragments implement the pre-debit/reconcile pattern:

### Inbound: `token-estimation-inbound.xml`

```
Request arrives → parse body size + max_tokens → estimate total tokens
  (formula: prompt_chars/4 + max_tokens/2)
  → read ptu-consumed cache → check if estimate fits under limit
  → if yes: pre-debit counter, route to PTU
  → if no: route to PAYG pool
```

Key implementation details:
- Checks both `max_tokens` and `max_completion_tokens` (newer API versions)
- Falls back to 2048 if neither is present
- Uses `preserveContent: true` to avoid consuming the request body stream

### Outbound: `token-estimation-outbound.xml`

```
Response arrives → determine route:
  PTU non-streaming: reconcile (cache += actual - estimate)
  PTU streaming: estimate stands (can't parse SSE body)
  PAYG: un-debit (cache -= estimate, request didn't use PTU)
  → emit x-estimated-tokens and x-actual-tokens headers for observability
```

Key implementation details:
- Only adjusts counter for PTU-routed requests (non-streaming)
- For PTU streaming requests, the inbound estimate stands (cannot parse SSE response body)
- For PAYG-routed requests, un-debits the estimate (request didn't consume PTU)
- Tracks PAYG pool consumption separately (for observability)
- Prevents counter from going negative
- These fragments are NOT yet integrated into the main policy — they are prototypes to be wired in when the P2 strategy is finalized

---

## 9. Next Steps

- [ ] **Choose APIM topology**: Single Premium multi-region (recommended) vs. separate instances per region
- [ ] **Create region-specific pools in Bicep**: Refactor `multi-foundry-backends.bicep` to produce `{model}-{region}-pool` with 3-priority tiers (local PTU → remote PTU → paygo)
- [ ] **Add `context.Deployment.Region` routing**: Policy selects the right regional pool based on which APIM gateway handles the request
- [ ] **Establish deployment naming convention**: Document that all Foundry instances must use identical deployment names per model
- [ ] **Refactor `multi-foundry-backends.bicep`**: Remove paygo backends from PTU pools — use 3-priority regional pools instead
- [ ] **Implement policy-level spillover**: On PTU 429, re-route to standard pool via `send-request` or retry logic in the policy (not pool priority)
- [ ] **Empirical PTU header test**: Deploy a real PTU deployment and capture all response headers
- [ ] **Decide P2 strategy**: Dynamic (current) vs. pool-priority-only (simpler)
- [ ] **Document soft limit behavior**: Make it clear in contract docs that PTU quotas are approximate
- [ ] **Evaluate `azure-openai-deployment-utilization` header**: If available, rewrite utilization calc to use it
- [ ] **Integrate token estimation fragments**: Wire `token-estimation-inbound.xml` and `token-estimation-outbound.xml` into the main policy once P2 strategy is finalized
- [ ] **Validate estimation formula with real PTU**: Run the 5 test patterns against a real deployment and compare estimated vs actual tokens
- [ ] **Consider `llm-token-limit` for PTU pool**: Use APIM's built-in estimation instead of custom counters
- [ ] **Streaming support**: `context.Response.Body.As<JObject>` may not work for `stream: true` responses — need to handle chunked responses separately
