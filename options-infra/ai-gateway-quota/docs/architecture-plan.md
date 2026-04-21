# Priority Queue for PTU OpenAI with APIM + Foundry

> ## Implementation Outcome (July 2025)
>
> After evaluating all 5 options below, the production implementation uses **APIM's native circuit breaker + priority-based backend pools**:
>
> - **Mixed pools per model** — PTU backends at priority 1, PAYG backends at priority 2. Circuit breaker on PTU backends (trips on 429/503, respects Retry-After) handles failover automatically.
> - **No loopback** — The earlier two-API loopback pattern (PTU Gate) was replaced with native circuit breaker failover. Simpler architecture, fewer moving parts.
> - **P2 removed** — Only P1 (production → mixed pool) and P3 (economy → PAYG only). The "PTU when idle" tier was eliminated.
> - **`llm-token-limit` everywhere** — Custom token estimation and cache-based counters deleted. `llm-token-limit` with custom `counter-key` handles all quota enforcement.
> - **Policy fragments** — Identity/contract logic in `fragment-identity.xml` shared across APIs via `<include-fragment>`.
> - **Foundry headers** — `x-foundry-agent-id`, `x-foundry-project-name`, `x-foundry-project-id` for agent tracing.
>
> The analysis below remains valuable for understanding the trade-offs and why alternatives were not chosen.

## Problem Statement

A customer deploys a PTU (Provisioned Throughput Units) Azure OpenAI deployment shared by multiple internal teams with different priorities (P1 production, P3 economy). The core challenge: standard APIM approaches give each subscriber independent TPM counters — when production is quiet, economy can't use the idle PTU capacity, leading to costly underutilization.

## Research Sources

| Source | Repo/Link | Key Pattern |
|--------|-----------|-------------|
| **AI-Gateway** | `Azure-Samples/AI-Gateway` (local) | Backend pool priority+weight, token rate limiting, circuit breakers, FinOps framework |
| **Citadel (AI Hub Gateway)** | [`Azure-Samples/ai-hub-gateway-solution-accelerator`](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) (citadel-v1 branch) | Access contracts, per-product token limits, model access control, usage tracking |
| **GenAI Gateway Playbook** | [MS Learn: Maximize PTU Utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization) | Event Hub queue pattern, orchestration service, dynamic PTU utilization monitoring |
| **ai-gw-v2** | [`Heenanl/ai-gw-v2`](https://github.com/Heenanl/ai-gw-v2) (usecaseonboard / jwtauth branches) | Multi-region priority pools, Entra ID JWT auth, Citadel access contracts |
| **SimpleL7Proxy** | [`microsoft/SimpleL7Proxy`](https://github.com/microsoft/SimpleL7Proxy) | Priority queuing L7 proxy, per-user profiles, sync+async modes, PTU→PAYG spillover |
| **ai-policy-engine** | [`Azure-Samples/ai-policy-engine`](https://github.com/Azure-Samples/ai-policy-engine) | ASP.NET 10 + APIM, per-tenant billing (Redis + CosmosDB), monthly quotas, RPM/TPM limits, React dashboard. Heavier infrastructure but stronger on chargeback/billing. |

---

## Option Summaries

### Option 1: Citadel (Static Limits)

Proven Citadel IaC pattern with access contracts defining fixed per-team TPM allocations. Lowest complexity (days of effort, mostly config), but PTU utilization is only 40–70% because unused production allocation is wasted — economy teams can't borrow idle capacity.

### Option 2: Citadel + Oversubscription

Same as Option 1 with oversubscribed TPM allocations (sum of team limits exceeds PTU capacity). Better utilization (70–85%) but no priority guarantee during contention — both tiers compete equally.

### Option 3: Custom APIM Policy (Chosen)

Custom C# policy logic within APIM XML policies. Uses response headers (`x-ratelimit-remaining-tokens`) to track PTU utilization and route P2 traffic dynamically. Highest utilization (85–95%) with strong priority guarantees. Medium complexity (~200 lines of policy). **This was the basis for the production implementation**, simplified with `llm-token-limit` and the two-API loopback.

### Option 4: Event Hub Queue (GenAI Playbook)

Queues P2 requests in Event Hub, processes them when PTU has capacity. Highest utilization for async workloads (95%+), but P2 must be asynchronous — not suitable for synchronous chat. High complexity (Event Hub + orchestration service + monitoring).

### Option 5: SimpleL7Proxy

Microsoft-maintained open-source L7 proxy with true priority queuing. Deploys on Azure Container Apps alongside APIM. Highest utilization (85–95%) with the strongest priority guarantees (preemptive queue). Medium complexity but adds an extra hop and in-memory state (not shared across replicas).

### Reference: ai-policy-engine

An ASP.NET 10 + APIM reference implementation for AI gateway governance. Architecture: APIM validates JWT → calls precheck API on Container Apps → forwards to model → calls `/api/log` for accounting. Uses Redis (write-through cache) + CosmosDB (durable store) with a React dashboard. Supports per-tenant billing (`clientAppId:tenantId`), monthly quotas, RPM/TPM limits, deployment allowlists, and billing modes (token/multiplier/hybrid). Heavier infrastructure (external API + Redis + Cosmos) compared to this project's APIM-native approach, but significantly stronger on chargeback and billing. No explicit PTU/PAYG priority routing concept.

---

## What Citadel Does Well

- Proven IaC pattern (Bicep + JSON contracts)
- Per-team model access control with allow-lists
- Per-team TPM limits via `llm-token-limit` / `azure-openai-token-limit`
- Backend pool routing with priority/weight and circuit breaker
- Content safety and PII handling (optional)

## What Citadel Does NOT Solve

- Dynamic PTU sharing — teams get fixed allocations; idle capacity is wasted
- Priority preemption — no mechanism to route lower-priority traffic to PAYG when PTU is busy
- JWT-only auth — Citadel requires APIM Products + Subscription keys
- Monthly quotas — not in the original Citadel (added by `llm-token-limit`)

---

## Comparison Table

| Criteria | Option 1: Citadel | Option 2: Citadel + Oversub | Option 3: Custom Policy | Option 4: Event Hub | Option 5: SimpleL7Proxy | ai-policy-engine |
|---|---|---|---|---|---|---|
| **PTU Utilization** | ⭐⭐ (40-70%) | ⭐⭐⭐ (70-85%) | ⭐⭐⭐⭐⭐ (85-95%) | ⭐⭐⭐⭐⭐ (95%+ async) | ⭐⭐⭐⭐⭐ (85-95%) | N/A (no PTU routing) |
| **Priority Guarantee** | ⭐⭐⭐⭐ Strong | ⭐⭐ Weak | ⭐⭐⭐⭐ Strong | ⭐⭐⭐⭐⭐ Strongest | ⭐⭐⭐⭐⭐ Strongest | N/A |
| **Complexity** | ⭐⭐⭐⭐⭐ Lowest | ⭐⭐⭐⭐⭐ Lowest | ⭐⭐⭐ Medium | ⭐⭐ High | ⭐⭐⭐ Medium | ⭐⭐ High |
| **Development Effort** | Days | Days | 1-2 weeks | 2-4 weeks | 1-2 weeks | 2-4 weeks |
| **Chargeback/Billing** | ⭐⭐ Basic | ⭐⭐ Basic | ⭐⭐ Basic | ⭐⭐⭐ Moderate | ⭐⭐ Basic | ⭐⭐⭐⭐⭐ Full |
| **Sync/Async** | Sync | Sync | Sync | P1: Sync, P2: Async | Both | Sync |
| **Requires APIM Keys** | Yes | Yes | Optional | No | No | No (JWT) |
| **HA/DR** | ⭐⭐⭐⭐⭐ Native | ⭐⭐⭐⭐⭐ Native | ⭐⭐⭐⭐ Good | ⭐⭐⭐ Moderate | ⭐⭐⭐ Moderate | ⭐⭐⭐ Moderate |

---

## FinOps: Token Counting & Chargeback Approaches

> Moved from TODO.md — reference comparison of how different projects handle token counting for billing.

| | [AI-Gateway FinOps](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/finops-framework) | [Citadel](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) | [APIM Chargeback (seiggy)](https://github.com/seiggy/apim-chargeback) | [APIM Chargeback (andyogah)](https://github.com/andyogah/apim-openai-chargeback-environment) | [llm-token-limit (native)](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy) |
|---|---|---|---|---|---|
| **Token counting** | `azure-openai-emit-token-metric` → App Insights | Triple: emit-metric + response parsing + EventHub | APIM outbound → external ASP.NET API | APIM outbound → Azure Function | Internal APIM counters |
| **Reliability** | ⚠️ App Insights sampling/throttling risk | ⚠️ Mixed (EventHub path is durable) | ✅ Direct HTTP POST | ✅ Direct HTTP POST | ✅ In-memory, not throttled |
| **Identity tracking** | Product ID | appId, productName, subscriptionId | JWT claims (tid, aud, azp) | Subscription key | Counter key (any expression) |
| **Cost calculation** | KQL workbook (no pricing table) | Cosmos DB with per-model pricing | Redis + Cosmos DB with pricing API | Function + Redis | None |
| **Complexity** | Low | High (5 services) | High (full .NET platform) | Medium (Function + Redis) | Low (single policy) |

### APIM Data Pipeline Limitations for Chargeback

Customers building chargeback on APIM face a fundamental conflict between APIM's two logging mechanisms:

**`llm-emit-token-metric` → App Insights**: Near real-time, customizable (up to 5 custom dimensions), but subject to [App Insights sampling, throttling, and a 50K active time series limit](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-limits). High-cardinality dimensions (per-user, per-team) can exhaust the limit — metrics may be **silently dropped**. Not suitable as system of record for billing.

**`ApiManagementGatewayLlmLog` → Log Analytics**: Reliable (not sampled), complete record of every request, but **fixed schema** — no `callerId`, `teamName`, or `backendType` fields. Cannot add custom dimensions. Only workaround: inject custom headers in policy and join with `ApiManagementGatewayLogs` via `OperationId` in KQL — fragile and complex.

**The Gap**: The reliable source lacks identity. The customizable source can lose data. This is why every reference implementation builds a custom pipeline (EventHub, external APIs, or Functions). A native solution — custom dimension support on `ApiManagementGatewayLlmLog` — would eliminate all of this complexity.
