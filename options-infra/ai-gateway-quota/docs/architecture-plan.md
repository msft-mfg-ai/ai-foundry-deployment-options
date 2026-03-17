# Priority Queue for PTU OpenAI with APIM + Foundry

## Problem Statement

A customer deploys a **PTU (Provisioned Throughput Units)** Azure OpenAI deployment (e.g., `gpt-5.2-chat`). Multiple internal teams subscribe to this model with different priorities:

- **Priority 1** — Production use cases (Dev Team A prod, Dev Team B prod)
- **Priority 2** — Dev/Test use cases (Dev Team A dev, Dev Team B test)

**Goals:**
1. **Maximize PTU utilization** — PTU is pre-paid; unused capacity is wasted money
2. **Prioritize production traffic** — Prod requests should be served by PTU first
3. **Minimize prod spillover to PAYG** — Dev/test should spill to PAYG before prod does
4. **All requests succeed** — No request is dropped; PAYG acts as overflow

**Core Challenge:** Standard APIM approaches (including Citadel) give each subscriber a fixed TPM budget via `llm-token-limit`. These are **independent counters** — they don't form a shared pool. When prod is quiet and only using 10% of its allocation, dev/test can't use the remaining 90%. This leads to **PTU underutilization**, which is costly since PTU is billed regardless of usage.

---

## Research Sources

| Source | Repo/Link | Key Pattern |
|--------|-----------|-------------|
| **AI-Gateway** | `Azure-Samples/AI-Gateway` (local) | Backend pool priority+weight, token rate limiting, circuit breakers, FinOps framework |
| **Foundry-with-APIM** | Local `foundry-with-apim` repo | APIM + Foundry integration, backend pools with priority, circuit breaker Bicep |
| **Citadel (AI Hub Gateway)** | `Azure-Samples/ai-hub-gateway-solution-accelerator` branch `citadel-v1` (local) | Access contracts, per-product token limits, model access control, usage tracking |
| **GenAI Gateway Playbook** | [MS Learn: Maximize PTU Utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization) | Event Hub queue pattern, orchestration service, dynamic PTU utilization monitoring |
| **ai-gw-v2** | [Heenanl/ai-gw-v2](https://github.com/Heenanl/ai-gw-v2) branches `usecaseonboard` / `jwtauth` | Multi-region priority pools, Entra ID JWT auth (no API keys), Citadel access contracts, dual API format |
| **SimpleL7Proxy** | [microsoft/SimpleL7Proxy](https://github.com/microsoft/SimpleL7Proxy) | Priority queuing L7 proxy, per-user profiles, sync+async modes, APIM policy, fair-share governance, PTU→PAYG spillover |

---

## Analysis: ai-gw-v2 (`usecaseonboard` branch)

> Source: [Heenanl/ai-gw-v2 (usecaseonboard)](https://github.com/Heenanl/ai-gw-v2/tree/usecaseonboard)

### What It Does Differently

This repo is a streamlined implementation of the Citadel Access Contract pattern with two important additions:

1. **Entra ID JWT Auth (no API keys for authentication)** — Uses `validate-azure-ad-token` with per-deployment app roles. Callers authenticate with JWT, never with Cognitive Services keys.
2. **Subscription keys for routing/governance (separate from auth)** — APIM subscription keys are used to identify use cases for token limits and tracking, but authentication is JWT-only.

### Auth Flow
```
Request → APIM
  1. validate-azure-ad-token (JWT from Entra ID app registration)
  2. Check roles claim contains deployment name → 403 if missing
  3. Resolve caller identity (UPN or Graph lookup, cached 8h)
  4. authentication-managed-identity → forward to Azure OpenAI with APIM's own MSI
  5. Emit token metrics with Caller dimension from JWT
```

### Key Architecture Choices

| Feature | ai-gw-v2 (`usecaseonboard`) | Citadel (original) |
|---------|------|---------|
| **Auth** | Entra ID JWT + subscription key | API key OR JWT (configurable) |
| **Per-deployment access** | App roles in JWT | Model access list in product policy |
| **Caller tracking** | JWT `upn` / Graph SPN lookup (cached 8h) | Subscription ID or JWT claims |
| **Multi-region** | 3 regions with priority 1/2/3 | Configurable backends |
| **Subscription keys** | Required for product routing | Required for product routing |
| **Foundry integration** | Scaffolded, TODO | Working |
| **Token limits** | Per subscription+deployment | Per subscription or per model |

### Relevance to API-Key-Free Customers

For customers who **do not allow API keys** (even for routing), there are two paths:

**Path A: JWT-only with APIM Products (ai-gw-v2 pattern)**
- Auth: JWT validated by APIM
- Routing: Still uses APIM subscription keys for product identification, but the key is NOT an API key to AI services — it's an APIM routing key
- Token limits: `counter-key="@(context.Subscription.Id)"` — requires subscription

**Path B: JWT-only, no subscription keys at all**
- Auth: JWT validated by APIM
- Routing: Extract identity from JWT claims (`oid`, `roles`, custom claims)
- Token limits: `counter-key="@(((Jwt)context.Variables["jwt"]).Claims.GetValueOrDefault("oid", "default"))"`
- Priority classification: From JWT app role or custom claim (e.g., `priority` claim or role mapping)
- **Trade-off**: APIM Products can't be used for policy isolation — all policy logic must be at API level with `<choose>` blocks based on JWT claims

---

## Analysis: SimpleL7Proxy (Microsoft - open source)

> Source: [microsoft/SimpleL7Proxy](https://github.com/microsoft/SimpleL7Proxy)

### What It Is

SimpleL7Proxy is a **Microsoft-official, open-source** Layer 7 reverse proxy purpose-built for LLM workloads. It deploys on Azure Container Apps alongside APIM and provides what APIM cannot natively do: **true priority queuing with preemptive scheduling**.

This is essentially a production-grade, Microsoft-maintained version of what we described as "Option 5: SimpleL7Proxy" — except it's not YARP, it's a custom .NET proxy with a purpose-built priority queue.

### Architecture

```
  Clients → SimpleL7Proxy (ACA) → APIM (Priority-with-retry.xml policy) → Azure OpenAI backends
                 │                      │
           ┌─────┴──────┐        Backend selection:
           │ Priority    │        PTU vs PAYG,
           │ Queue       │        concurrency limits,
           │ P1 ■■■■     │        circuit breaker,
           │ P2 ■■■■■■■  │        retry + requeue
           │ P3 ■■       │
           └─────┬──────┘
                 │
           ProxyWorker threads
                 │
      ┌──────────┼──────────┐
      ▼          ▼          ▼
  APIM (WEU)  APIM (NEU)  APIM (EUS)     ← Host1-Host9 can be different APIM instances
      │          │          │
  OpenAI PTU  OpenAI PAYG  OpenAI PAYG
```

**SimpleL7Proxy is the entry point, not APIM.** The proxy sits in front of APIM:
- Proxy handles: priority queuing, user profiles, fair-share governance, async mode, connection management
- APIM handles: backend selection (PTU/PAYG), auth (Managed Identity to OpenAI), concurrency limits, circuit breaker, retry with `S7PREQUEUE` requeue signal, token metrics
- `Host1`-`Host9` on the proxy can point to **different APIM instances** (e.g., in different regions), enabling multi-region routing at the proxy level

### Key Features for Our Use Case

| Feature | How It Works | Relevance |
|---------|-------------|-----------|
| **Priority Queuing** | Incoming requests are classified by priority header (`llm_proxy_priority: 1/2/3`). Higher priority is **always dequeued first** — P1 preempts P2, even if P2 arrived earlier. | ✅ Directly solves "prod before dev/test" |
| **APIM Policy Integration** | Ships with `Priority-with-retry.xml` — a 38K-line APIM policy installed on the downstream APIM instance(s). Handles backend selection (PTU vs PAYG), concurrency limits, affinity, circuit breaker, and retry with requeue signals back to the proxy. | ✅ Not a "build from scratch" — comes with production APIM policy |
| **PTU → PAYG Spillover** | APIM policy backends configured with `acceptablePriorities` — e.g., PTU accepts priorities 1,2,3; PAYG only accepts priority 3. Proxy passes priority header; APIM routes accordingly. | ✅ Exactly our requirement |
| **User Profiles** | JSON config per user: priority level, async permissions, custom headers, per-user throttling. Loaded from URL/file, refreshed hourly. `S7PPriorityKey` maps user → priority. | ✅ Per-team priority assignment |
| **Fair-Share Governance** | `UserPriorityThreshold` (0.0-1.0) — if a user's active requests exceed this ratio of total queue, their requests are deprioritized. Prevents "noisy neighbor." | ✅ Prevents one team from monopolizing PTU |
| **Sync + Async Modes** | **Sync**: Request enters priority queue → ProxyWorker dequeues → calls backend → returns response to waiting HTTP connection. **Async**: If request exceeds `AsyncTriggerTimeout`, proxy returns `202 Accepted` + job ID. Result stored in Blob Storage, notification via Service Bus topic. | ✅ Handles both interactive chat AND batch workloads |
| **Circuit Breaker** | Per-backend circuit breaker. Trips on failures, auto-recovers. Combined with APIM policy's `S7PREQUEUE` signal for graceful throttling. | ✅ Resilient to backend failures |
| **Streaming Support** | Full support for SSE streaming responses with real-time token counting. | ✅ Works with chat completions |
| **Multi-Region LB** | Latency-based, weighted round-robin, or random backend selection. Path-based routing for different models. | ✅ Multi-region OpenAI backends |

### How Sync Priority Queue Works (Critical Detail)

Unlike the Event Hub pattern (Option 4), SimpleL7Proxy's sync mode **keeps the HTTP connection open**:

```
1. Client sends request to SimpleL7Proxy (the entry point)
2. Proxy identifies user (userId header), assigns priority from user profile
3. Server.cs inserts request into PriorityQueue
4. HTTP connection stays OPEN (client is waiting)
5. ProxyWorker pulls from queue — P1 first, then P2, then P3
6. ProxyWorker forwards to APIM (one of Host1-Host9, selected by load balancing)
7. APIM policy selects backend (PTU/PAYG), handles auth, concurrency, retry
8. If APIM returns S7PREQUEUE header (soft throttle) → proxy requeues the request
9. Response streamed back: OpenAI → APIM → Proxy → Client (open connection)
```

**This means**: Chat completions, Foundry agents, streaming — all work in sync mode. The "queue" adds only milliseconds of latency when the system isn't overloaded. Under load, P2 waits longer (seconds) while P1 is processed first — but the connection is never dropped.

### How Async Mode Works (For Long-Running Tasks)

Async is **opt-in per request** via an `AsyncMode: true` header AND per-user config:

```
1. Client sends request with AsyncMode: true
2. Request enters priority queue (same as sync)
3. If backend doesn't respond within AsyncTriggerTimeout:
   → Proxy returns 202 Accepted + requestId + blobUrl + Service Bus topic
   → Client's HTTP connection is closed
4. ProxyWorker continues waiting for backend response
5. Response stored in Azure Blob Storage (per-user container)
6. Status notification sent to user's Service Bus topic
7. Client retrieves result from Blob Storage via SAS URL
```

**Per-user async config** in user profile:
```json
{
  "userId": "batch-team-a",
  "S7PPriorityKey": "low-priority-key",
  "async-config": "enabled=true, containername=team-a-results, topic=team-a-status, timeout=3600"
}
```

### APIM Policy: Priority-with-retry

The bundled APIM policy is a **38K-line production policy** — not a snippet. Key features:

- **Backend definition with priority + acceptable priorities**: Each backend declares which priority levels it serves
  ```xml
  { "url", "https://ptu-endpoint.openai.azure.com/" },
  { "priority", 1 },                    // backend's own priority (routing order)
  { "ModelType", "PTU" },               // label
  { "acceptablePriorities", [1, 2, 3] }, // which request priorities this backend handles
  { "LimitConcurrency", "high" },       // high=100, medium=50, low=10
  ```
- **Priority-based backend filtering**: Low-priority requests only sent to backends that accept them
- **Concurrency control**: Per-backend limits prevent overloading
- **Requeue signal**: On 429, returns `S7PREQUEUE: true` header to proxy → proxy requeues instead of failing
- **Affinity**: Sticky session support for OpenAI cache optimization
- **Can be used standalone** (without SimpleL7Proxy) as a pure APIM priority routing policy

### Comparison: SimpleL7Proxy vs Our Other Options

| Aspect | SimpleL7Proxy | Option 3 (Custom APIM Policy) | Option 4 (Event Hub) |
|--------|--------------|-------------------------------|---------------------|
| **Priority queuing** | True preemptive queue (P1 always first) | No queue — per-request routing decision | Queue but P2 is fully async |
| **Sync support** | ✅ Connection stays open | ✅ Native APIM passthrough | ❌ P2 must be async |
| **Async support** | ✅ Opt-in per request/user | ❌ Not supported | ✅ P2 is always async |
| **PTU monitoring** | Real-time via response headers + circuit breaker | Cache `x-ratelimit-remaining-tokens` | Azure Monitor (1-5min lag) |
| **User-level governance** | ✅ Per-user profiles, fair-share, throttling | ⚠️ Per-subscription or JWT claim | ❌ Per-priority-tier only |
| **APIM integration** | Ships with production APIM policy | You write the policy | APIM classifies only |
| **Microsoft supported** | ✅ microsoft/ org repo | ❌ Custom code | ✅ Reference architecture |
| **Extra infra** | ACA (Container Apps) | None (APIM only) | Event Hub + Function + Storage |
| **Streaming** | ✅ Full SSE support with token counting | ✅ APIM native | ❌ Not through queue |
| **Latency overhead** | ~5-20ms (extra network hop) | ~1-5ms (cache lookup) | Seconds to minutes (P2) |

### What It Doesn't Do

- **No Citadel access contracts** — user profiles are its own JSON format, not Bicep-deployed APIM Products
- **No APIM subscription-based identification** — uses custom headers (`userId`) for identity, not `context.Subscription.Id`
- **No built-in Foundry connection management** — transparent proxy, Foundry sees it as a standard endpoint
- **Requires ACA operational expertise** — you're running a container service, not just configuring APIM

---

> Source: [Microsoft Learn — Approaches for maximizing PTU utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization)

### What It Solves

PTUs are **billed regardless of usage**. If you reserve 100 PTU (e.g., 600,000 TPM) but only use 200,000 TPM on average, you're wasting 67% of your investment. The Playbook's core insight: **fill idle PTU capacity with low-priority work.**

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        APIM Gateway                              │
│  Classify by priority (header, path, or product)                 │
├──────────────────────┬──────────────────────────────────────────┤
│                      │                                           │
│   P1 (High Priority) │   P2 (Low Priority)                      │
│   ──────────────────►│   ──────────────────►                     │
│   Direct passthrough │   Routed to Event Hub queue               │
│                      │                                           │
└──────┬───────────────┴───────────────┬───────────────────────────┘
       │                               │
       ▼                               ▼
┌──────────────┐              ┌─────────────────┐
│  Azure OpenAI │              │   Event Hub      │
│  PTU Deploy.  │◄─────────────│   (P2 queue)     │
│              │              └────────┬──────────┘
│  Sync resp.  │                       │
└──────────────┘              ┌────────▼──────────┐
                              │  Orchestrator      │
                              │  (Function/        │
                              │   Container App)   │
                              │                    │
                              │  Monitors PTU      │
                              │  utilization       │
                              │                    │
                              │  Controls PULL     │
                              │  RATE from queue   │
                              └────────────────────┘
```

### How It Actually Works (Step by Step)

**1. Request Classification (APIM)**
- APIM inspects incoming requests and classifies them as P1 or P2
- Classification can be based on: APIM Product, custom header (`x-priority`), or URL path
- P1 → forwarded directly to PTU (synchronous, normal APIM flow)
- P2 → published to Event Hub (asynchronous, request is acknowledged but not yet processed)

**2. Queue Buffering (Event Hub)**
- P2 requests sit in the Event Hub until the orchestrator pulls them
- Event Hub provides ordering, partitioning, and retention
- The queue decouples the arrival rate of P2 from the processing rate

**3. Orchestrator (the key component)**
- A background service (Azure Function, Container App, or AKS pod)
- Controls HOW FAST it pulls messages from Event Hub
- Adjusts pull rate based on PTU utilization:

```
PTU Utilization         Orchestrator Behavior
─────────────────       ──────────────────────
< 20% (lower limit)  → Pull at maximum rate (e.g., 10 concurrent requests)
20% - 90%            → Linearly reduce rate (10 → 1 concurrent requests)
> 90% (upper limit)  → PAUSE pulling entirely (all PTU reserved for P1)
```

**4. Utilization Monitoring (two approaches)**

| Approach | How It Works | Latency | Accuracy |
|----------|-------------|---------|----------|
| **Azure Monitor** | Orchestrator queries `Provisioned-Managed Utilization V2` metric via Azure Metrics API | 1-5 min (typical), up to 15 min (worst case) | Exact (Azure's own counter) |
| **Custom Events** | APIM emits token counts to Event Hub → Stream Analytics aggregates in windows → writes to state store → orchestrator reads | 5-30s (depending on window size) | Approximate (your own calculation, may drift from Azure's counter) |

**5. Response Delivery (the part most architectures gloss over)**
- The P2 caller's HTTP connection was already closed when APIM returned `202 Accepted`
- The orchestrator has the OpenAI response, but the caller is no longer connected
- The orchestrator must write the result to a **result store** (Cosmos DB, Service Bus response queue, or blob storage)
- The caller retrieves the result by: polling a status endpoint (`GET /jobs/{id}`), listening on a response queue, or receiving a webhook callback
- **This is the Async Request-Reply pattern** ([Azure Architecture Center](https://learn.microsoft.com/en-us/azure/architecture/patterns/async-request-reply))
- This fundamentally **does not work** for chat completions, Foundry agents, streaming responses, or any interactive workload — see Option 4 details below for a full compatibility matrix

### How It Handles PTUs Being Pre-Purchased TPM

The Playbook's design directly maps to how PTU capacity works:
- PTU capacity = fixed TPM per minute (what you bought)
- Utilization % = (actual tokens processed this minute / max TPM) × 100
- The orchestrator's thresholds (20%/90%) are effectively **TPM thresholds**:
  - 20% of max TPM → start throttling P2
  - 90% of max TPM → stop P2 entirely, reserve remaining 10% as buffer for P1
- The pull rate controls how many P2 tokens per minute are submitted to PTU
- This directly controls what share of the TPM budget goes to P2

### Why the Monitoring Lag Isn't Fatal

My earlier timing analysis treated this like per-request routing. But the queue changes the math:

**Per-request routing (Options 1-3, 5):**
```
Request arrives → Check metric → Route to PTU or PAYG → Done
If metric is stale → Wrong routing decision for THIS request
```

**Queue-based rate control (Option 4):**
```
Orchestrator reads utilization → Adjusts PULL RATE → Rate applies to ALL future pulls
If metric is stale → Pull rate is temporarily too high/low
Queue absorbs the difference → System self-corrects on next reading
```

The queue acts as a **shock absorber**. During the 1-5 minutes of monitoring lag:
- **Overshoot** (pulling too fast): Some P2 requests hit PTU that shouldn't have → PTU returns 429 → orchestrator backs off (reactive correction on top of proactive monitoring)
- **Undershoot** (pulling too slow): P2 requests queue up but aren't lost → processed when rate increases

**The threshold buffer is the key design element:**
- Lower limit (20%) and upper limit (90%) create a **70% operating range**
- The 10% gap between upper limit (90%) and actual throttling (100%) = **safety buffer** for monitoring lag
- Even with 5-minute stale data, rate adjustments are gradual, not binary
- During a sudden P1 spike, the worst case is: P2 overshoots for a few minutes → queue + 429 backoff corrects it

### When This Approach Excels

| Scenario | Why It Works Well |
|----------|-------------------|
| **Batch embeddings** | P2 can wait minutes/hours. Queue is natural. |
| **Document summarization** | Async by nature. Results stored, not streamed. |
| **Data pipeline enrichment** | ETL-style: queue → process → store. No real-time requirement. |
| **Nightly/periodic processing** | Fill PTU during off-hours when P1 traffic is low. |
| **Workloads with predictable P1 patterns** | If P1 traffic follows daily patterns (e.g., business hours), the lag is irrelevant because changes are gradual. |

### When This Approach Struggles

| Scenario | Why It Struggles |
|----------|-----------------|
| **Synchronous chat completions** | P2 users expect real-time responses. Queue latency is unacceptable. |
| **Foundry Agent Services** | Agents expect synchronous model responses. Can't wait in a queue. |
| **Unpredictable P1 traffic spikes** | Sudden spike + monitoring lag → orchestrator doesn't pause fast enough → P2 competes briefly. Buffer mitigates but doesn't eliminate. |
| **Interactive dev/test** | Developers testing prompts want instant responses, not "your request is queued." |

### Why It's in the Architecture Center

1. **It's the only pattern that truly guarantees P1 zero-interference** — P1 goes direct to PTU, never competes with P2 at the APIM layer
2. **Maximizes PTU ROI for batch workloads** — fills close to 100% of idle capacity (huge use case for embeddings, fine-tuning data prep)
3. **Clean separation of concerns** — sync path (P1) and async path (P2) are completely independent
4. **Self-correcting** — queue + rate control + threshold buffers handle monitoring lag gracefully
5. **Azure-native building blocks** — Event Hub, Stream Analytics, Functions are all managed services with SLAs
6. **Proven pattern** — queue-based priority processing is a well-established distributed systems pattern (not AI-specific)

### Honest Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| PTU utilization (batch P2) | ⭐⭐⭐⭐⭐ 95%+ | Queue fills ALL idle capacity. Best possible utilization for async workloads. |
| PTU utilization (sync P2) | N/A | Can't be used for sync P2 workloads. |
| P1 protection | ⭐⭐⭐⭐⭐ | P1 never touches the queue. Direct passthrough. Zero interference. |
| Monitoring lag impact | ⭐⭐⭐ Mitigated | Threshold buffers (10%) absorb lag. Queue smooths overshoot. Brief P2 competition during sudden P1 spikes. |
| Complexity | ⭐⭐ High | Event Hub + orchestrator + Stream Analytics (optional) + async response delivery mechanism. |
| Operational burden | ⭐⭐ High | Orchestrator scaling, queue monitoring, dead letter handling, response delivery. |

---

## PTU, TPM, and "Utilization" — How They Relate

This is a critical concept that the GenAI Playbook doc doesn't explain clearly.

### The Three Concepts

| Concept | What It Is | Example |
|---------|-----------|---------|
| **PTU** (Provisioned Throughput Units) | Generic units of reserved model processing capacity. **What you buy.** | 100 PTU for gpt-5.2-chat |
| **TPM** (Tokens Per Minute) | The actual throughput your PTU reservation provides. **What you measure.** Each PTU translates to a model-specific number of TPM. | 100 PTU → ~600,000 TPM (varies by model) |
| **Provisioned-Managed Utilization V2** | Azure Monitor metric: `(tokens processed in 1 min ÷ max TPM of your PTUs) × 100%`. **What you monitor.** Sampled at 1-minute intervals. | Used 300k tokens in 1 min with 600k TPM capacity → 50% utilization |

### Key Insight: Everything Is Per-Minute

You're correct — **PTU capacity is fundamentally a per-minute concept (TPM)**. The "utilization" percentage in the GenAI Playbook is just `actual_TPM / max_TPM × 100%`. When utilization hits ~100%, the deployment returns 429 errors.

This means:
- **APIM's `llm-token-limit` policy** works correctly for this — it enforces TPM limits per subscription, which directly maps to PTU capacity
- **The GenAI Playbook's "utilization thresholds"** (e.g., pause low-priority at 90%) are really TPM thresholds (e.g., pause when remaining TPM < 10% of max)
- **Response headers** like `x-ratelimit-remaining-tokens` and `x-ratelimit-remaining-requests` reflect real-time per-minute capacity remaining

### How This Affects Each Option

| Option | How It Uses Per-Minute Metrics |
|--------|-------------------------------|
| **Option 1 (Citadel)** | `llm-token-limit tokens-per-minute="X"` directly caps per-subscriber TPM. Aligns perfectly with PTU capacity model. |
| **Option 2 (Oversubscription)** | Same as Option 1 — just higher TPM values. When combined TPM exceeds PTU capacity in a given minute, circuit breaker + PAYG spillover handles it. |
| **Option 3 (Custom APIM Policy)** | Caches `x-ratelimit-remaining-tokens` from PTU responses (per-minute remaining). Uses this to decide whether P2 should go to PTU or PAYG. This IS a per-minute decision. |
| **Option 4 (Event Hub Queue)** | Orchestrator monitors `Provisioned-Managed Utilization V2` metric (per-minute %). When utilization is high in current minute, slows/pauses queue drain. **Caveat: Azure Monitor has 30s-15min latency** for this metric, so the orchestrator is always reacting to slightly stale data. |
| **Option 5 (YARP)** | Can read `x-ratelimit-remaining-tokens` headers in real-time from every PTU response. Most accurate per-minute picture. |

### The Timing Paradox: Azure Monitor vs 1-Minute PTU Windows

**PTU throttling is per-minute.** The PTU deployment uses a rolling 1-minute window:
- Token counter accumulates within the window
- When counter ≥ TPM quota → 429 with `Retry-After` header (seconds until next window)
- At window boundary, counter resets to 0
- `x-ratelimit-remaining-tokens` in each response shows remaining capacity in the current window

**Azure Monitor has 1-5 minute latency** (MS docs: "typically within one minute"; GenAI Playbook says "30 seconds to 15 minutes"):

```
Timeline of a traffic spike:

T=0:00  PTU utilization: 30%    Azure Monitor shows: ~30% (from T-2min)    Orchestrator: draining P2 ✅
T=0:15  Prod burst arrives
T=0:30  PTU utilization: 70%    Azure Monitor shows: ~30% (STALE)          Orchestrator: still draining P2 ⚠️
T=0:45  PTU utilization: 95%    Azure Monitor shows: ~50% (catching up)    Orchestrator: still draining P2 ❌
T=0:55  PTU hits 100% → 429s    Azure Monitor shows: ~70%                  Orchestrator: STILL draining P2 ❌
T=1:00  ─── PTU window resets to 0% ─── Counter starts fresh ───
T=1:01  PTU utilization: 5%     Azure Monitor shows: ~90% (from T=0:45)    Orchestrator: PAUSES P2 (wrong!) ❌
T=1:30  PTU utilization: 10%    Azure Monitor shows: ~95% (from T=0:55)    Orchestrator: still paused ❌
T=2:00  PTU utilization: 15%    Azure Monitor finally shows T=1:00's 5%    Orchestrator: resumes P2 ✅
```

**The core problem: Azure Monitor latency (1-5 min) is in the same order of magnitude as the PTU window (1 min).** The orchestrator is always making decisions about the PREVIOUS minute — which has already reset. It will:
1. **Push P2 traffic during a spike** (because it sees stale low utilization)
2. **Pause P2 traffic after the spike passes** (because it sees stale high utilization)

This is the OPPOSITE of what you want.

**The custom events mitigation** (Event Hub + Stream Analytics) reduces latency to seconds, but:
- Stream Analytics uses windowed aggregation (tumbling/sliding windows)
- Even a 10-second window means you're 10 seconds behind
- And the utilization you calculate is YOUR estimate, not Azure's actual counter — there will be drift

### What Actually Works in Real-Time

| Signal | Latency | Scope | When Available |
|--------|---------|-------|----------------|
| **429 error** | Instant (0ms) | Per-request | Only AFTER capacity is exceeded |
| **`x-ratelimit-remaining-tokens` header** | Instant (0ms) | Per-response | Every successful response |
| **`x-ratelimit-remaining-requests` header** | Instant (0ms) | Per-response | Every successful response |
| **`Retry-After` header** | Instant (0ms) | Per-429 response | Only on throttled responses |
| **APIM circuit breaker** | ~seconds | Per-backend | After N failures in window |
| **APIM `llm-token-limit` counter** | Instant (0ms) | Per-subscription | Every request (APIM-side counter) |
| **Azure Monitor utilization metric** | 1-5 min | Per-deployment | Always delayed |
| **Custom Event Hub + Stream Analytics** | ~5-30s | Custom calculation | Requires windowed aggregation |

### Revised Conclusion

**Reactive 429-based approaches (Options 1-3, 5) are actually MORE effective for per-minute routing than "proactive" Azure Monitor-based approaches (Option 4).** The 429 + circuit breaker + Retry-After mechanism is:
- Instant (zero latency)
- Based on the actual PTU counter (not an estimate)
- Aligned with the 1-minute window

**Option 4 (Event Hub Queue) makes sense for:**
- **Gradual traffic pattern changes** (hours/days, not minutes)
- **Capacity planning and trending** (are we consistently over/under-provisioned?)
- **Cost optimization alerts** (PTU utilization <50% over 24 hours → consider reducing PTU)
- **NOT for real-time per-minute routing decisions**

**Option 3 (Custom APIM Policy) with `x-ratelimit-remaining-tokens` caching is the sweet spot:**
- Reads real-time remaining capacity from every PTU response
- Caches it for P2 routing decisions
- Zero monitoring delay
- Stays within APIM (no additional infrastructure)
- The 60-second cache TTL aligns well with the 1-minute PTU window

---

## How Citadel Does It

Citadel implements an **Access Contracts** framework — a JSON-driven, IaC-first approach to subscriber onboarding:

### Architecture
```
Access Contract JSON → Bicep Deployment → APIM Product + Product Policy + Subscription + Key Vault Secrets
```

### Key Components
1. **Access Contract** — A JSON file per subscriber defining:
   - `contractInfo`: business unit, use case, environment (DEV/PROD)
   - `policies.modelAccess`: which models the subscriber can use
   - `policies.capacityManagement`: TPM + monthly token quota
   - `policies.contentSafety`, `policies.piiHandling`: governance guardrails
   - `policies.usageTracking`: custom App Insights dimensions

2. **APIM Product per contract** — Each access contract creates a dedicated APIM Product with:
   - Product-level policy XML (auto-generated from contract JSON)
   - `llm-token-limit` per subscription with configurable TPM + quota
   - Model access validation via `validate-model-access` fragment
   - Optional content safety, PII anonymization

3. **Backend Pool Routing** — Model-based routing with priority+weight:
   - Backend pool created per model (e.g., `gpt-4o-backend-pool`)
   - Each pool has backends with `priority` (lower=higher) and `weight`
   - Circuit breaker on 429 (3 failures in 10s → 10s trip)
   - Retry: 2 attempts with first-fast-retry

4. **Capacity Management Modes**:
   - `subscription-level`: Single TPM limit across all models
   - `per-model`: Different TPM limits per model per subscription

### Example Access Contract (Citadel)
```json
{
  "contractInfo": { "businessUnit": "Sales", "useCaseName": "Assistant", "environment": "PROD" },
  "policies": {
    "modelAccess": { "enabled": true, "allowedModels": ["gpt-5.2-chat"] },
    "capacityManagement": {
      "enabled": true,
      "mode": "subscription-level",
      "subscriptionLevel": { "tokensPerMinute": 10000, "tokenQuota": 5000000, "tokenQuotaPeriod": "Monthly" }
    }
  }
}
```

### What Citadel Does Well ✅
- Clean IaC-driven onboarding (JSON → Bicep → APIM)
- Per-subscriber model access control + governance (PII, content safety)
- Usage tracking with custom dimensions for chargeback
- Circuit breaker + retry for backend resilience

### What Citadel Does NOT Solve ❌
- **No shared capacity pool** — Each subscriber's `llm-token-limit` is an independent counter
- **No dynamic priority** — If prod uses 10% of its 80k TPM, the other 70k is NOT available to dev/test
- **PTU underutilization** — Subscribers can't "borrow" unused capacity from other tiers
- **No real-time utilization awareness** — Routing decisions don't consider current PTU load

---

## Options Analysis

### Option 1: Citadel Access Contracts (APIM Products + Static Token Limits)

**How it works:** Each priority tier gets an APIM Product with a fixed `llm-token-limit`. Both share the same backend pool (PTU priority=1, PAYG priority=2). Dev/test gets a lower TPM allocation, effectively reserving more PTU headroom for prod.

```
Prod (P1):     TPM = 80% of PTU capacity → PTU → PAYG spillover
Dev/Test (P2): TPM = 30% of PTU capacity → PTU → PAYG spillover
```

**PTU utilization scenario (the problem):**
- If prod uses only 10% → 70% of PTU sits idle
- Dev/test capped at 30% → total utilization = 40%
- **60% of PTU is wasted**

---

### Option 2: Enhanced Citadel with Oversubscription

**How it works:** Same as Option 1, but with aggressive oversubscription. Give both tiers high limits (totaling >>100% of PTU), relying on the backend pool circuit breaker + PAYG spillover to handle contention.

```
Prod (P1):     TPM = 100% of PTU capacity → PTU → PAYG spillover
Dev/Test (P2): TPM = 100% of PTU capacity → PTU → PAYG spillover
```

**Why this is better for utilization but NOT for priority:**
- Both priorities compete equally for PTU
- When PTU is saturated, it's random who gets 429'd and spills to PAYG
- Prod and dev/test have equal chance of hitting PAYG — **no priority guarantee**

---

### Option 3: Custom APIM Policy (Dynamic Priority-Aware Routing)

**How it works:** A custom APIM policy (extending the deprecated `advanced-load-balancing/policy.xml` from AI-Gateway) that:
1. Identifies subscriber priority from Product/Subscription context
2. Tracks PTU utilization state in APIM cache (via `x-ratelimit-remaining-tokens` response headers)
3. Routes Priority 1 → always PTU first, PAYG on 429
4. Routes Priority 2 → PTU only when cached utilization < threshold (e.g., 70%), else direct to PAYG

```
                    ┌─────────────────────────────────────────┐
                    │     Custom APIM Policy (Inbound)         │
                    │                                          │
  P1 (Prod) ───────►  Always → PTU ──429──► PAYG              │
                    │                                          │
  P2 (Dev/Test) ──►  Check cached utilization:                │
                    │  < 70% → PTU ──429──► PAYG               │
                    │  ≥ 70% → Direct to PAYG                  │
                    └─────────────────────────────────────────┘
```

**Key technical detail:** After each PTU response, the policy caches `x-ratelimit-remaining-tokens` in APIM's internal cache (60s TTL). Priority 2 requests read this cache to decide routing.

---

### Option 4: GenAI Gateway Playbook (Event Hub Priority Queue)

**How it works:** Based on the [Microsoft Learn reference architecture](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization):
1. APIM classifies requests by priority (header or product)
2. **Priority 1 → Direct to PTU** (synchronous, low latency)
3. **Priority 2 → Event Hub queue** (asynchronous)
4. **Orchestration service** (Function App / Container App) monitors PTU utilization:
   - Via Azure Monitor metrics (30s-15min latency), OR
   - Via custom token events from APIM → Event Hub → Stream Analytics (near real-time)
5. Orchestrator pulls from queue when PTU has capacity, throttles/pauses when busy

```
  P1 ─────► APIM ─────► PTU ─────► Response (sync, normal HTTP)
                │
  P2 ─────► APIM ─────► Event Hub ─────► Orchestrator ─────► PTU
                │                                               │
         202 Accepted                                    Response stored
         + job ID                                        in result store
                                                                │
  P2 caller polls ◄──────── Result Store (Cosmos DB / Storage / Service Bus) ◄──┘
  or receives callback
```

**⚠️ CRITICAL: P2 is fully async — the caller does NOT get a direct HTTP response.**

The P2 request flow is:
1. P2 caller sends request to APIM
2. APIM publishes the request body to Event Hub and returns `202 Accepted` + a `job-id`
3. P2 caller's HTTP connection is **closed** — no response body yet
4. Orchestrator eventually pulls the message, calls OpenAI, gets the completion
5. Orchestrator writes the result to a **result store** — this could be:

| Result Store | P2 Caller Retrieves Via | Latency to Retrieve | Complexity |
|---|---|---|---|
| **Service Bus response queue** (per caller) | Caller listens on its own queue | Near-instant after processing | Medium — need queue-per-caller or correlation ID |
| **Cosmos DB / Table Storage** | Caller polls `GET /jobs/{job-id}` endpoint | Poll interval (1-5s) | Low — simple key-value lookup |
| **Callback webhook** | Orchestrator POSTs to caller's URL | Near-instant after processing | Medium — caller must expose an endpoint |
| **Azure SignalR / Web PubSub** | Real-time push notification | Near-instant after processing | High — requires SignalR infra |

**What this means for different workload types:**

| Workload | Compatible? | Why |
|---|---|---|
| **Batch embeddings** | ✅ Yes — perfect fit | Fire-and-forget. Results stored in vector DB. Caller doesn't wait. |
| **Document summarization** | ✅ Yes | Async pipeline. Submit doc → get summary later. |
| **Chat completions** | ❌ No | User is staring at a chat UI waiting for a response. Polling/queueing adds seconds to minutes of latency. Streaming (`stream: true`) is impossible through a queue. |
| **Foundry Agents** | ❌ No | Agents are synchronous multi-turn: send message → get response → make tool calls → send follow-up. Each turn must be sync. An agent can't "wait for a queue." |
| **Interactive dev/test** | ❌ No | Developers testing prompts expect instant responses, not "your request is queued, poll for results." |
| **RAG pipelines (real-time)** | ❌ No | User asks a question → retrieve docs → generate answer. Must be sync end-to-end. |
| **RAG pipelines (batch indexing)** | ✅ Yes | Enriching index with AI summaries/embeddings is async by nature. |

**Graceful degradation:**
- PTU utilization < 20%: Max concurrency for low-priority
- 20-90%: Gradually reduce low-priority throughput
- \> 90%: Pause low-priority entirely (all PTU for prod)

**How the orchestrator monitors per-minute PTU utilization:**

PTU capacity resets every minute. The orchestrator has three signals, each with trade-offs:

| Signal | How Orchestrator Gets It | Latency | Per-Minute Alignment |
|---|---|---|---|
| **Azure Monitor metric** (`Provisioned-Managed Utilization V2`) | Poll Azure Metrics API every 30-60s | 1-5 min behind | ❌ Sees previous minute(s), not current. But rate control + queue buffer smooths this. |
| **Custom token counting** (APIM → Event Hub → Stream Analytics) | Stream Analytics tumbling window (e.g., 30s) writes to state store, orchestrator reads | 5-30s behind | ⚠️ Approximate — counts YOUR tokens, not Azure's internal counter. Drift is possible. |
| **`x-ratelimit-remaining-tokens` response header** | Orchestrator reads this from every OpenAI response it receives | 0ms (real-time) | ✅ Exact remaining capacity RIGHT NOW. But only visible on responses to orchestrator's own requests — doesn't see P1 consumption directly. |

**Best practice: Combine signals.** The orchestrator uses `x-ratelimit-remaining-tokens` from its own responses as the primary signal (real-time, exact), with Azure Monitor as a secondary/calibration signal. When the remaining-tokens header shows capacity dropping fast (P1 spike), the orchestrator immediately reduces pull rate — no need to wait for Azure Monitor.

---

### Option 5: SimpleL7Proxy (Microsoft L7 Priority Proxy)

**How it works:** Deploy [microsoft/SimpleL7Proxy](https://github.com/microsoft/SimpleL7Proxy) on Azure Container Apps between APIM and Azure OpenAI:
1. APIM handles auth, subscription management, metrics + the bundled `Priority-with-retry.xml` policy
2. SimpleL7Proxy implements **true preemptive priority queue** — P1 always dequeued before P2
3. Supports 3 priority levels with configurable backend acceptance (PTU accepts P1+P2, PAYG accepts P3 only)
4. Per-user profiles with fair-share governance (noisy neighbor prevention)
5. Sync mode: HTTP connection stays open through the queue — works for chat, agents, streaming
6. Async mode (opt-in): Long-running requests return 202 Accepted, result in Blob Storage, notification via Service Bus
7. Circuit breaker + retry with requeue signal (`S7PREQUEUE` header)

```
  All requests --> SimpleL7Proxy (ACA) --> APIM (Priority-with-retry.xml) --> OpenAI
                        |
                  Priority Queue
                  P1 (immediate)    --> APIM --> PTU
                  P2 (when P1 done) --> APIM --> PTU or PAYG
                  P3 (lowest)       --> APIM --> PAYG only
  
  Host1-Host9 can be different APIM instances (multi-region)
```

See [Analysis: SimpleL7Proxy](#analysis-simplel7proxy-microsoft) for full details.


## Comparison Table

| Criteria | Option 1: Citadel (Static Limits) | Option 2: Citadel + Oversubscription | Option 3: Custom APIM Policy | Option 4: Event Hub Queue (GenAI Playbook) | Option 5: SimpleL7Proxy |
|---|---|---|---|---|---|
| **Cost Effectiveness (PTU Utilization)** | ⭐⭐ Low (40-70%) — Unused prod allocation is wasted. Dev/test can't borrow idle capacity. | ⭐⭐⭐ Medium (70-85%) — Better utilization but no priority guarantee during contention. | ⭐⭐⭐⭐⭐ Highest (85-95%) — Real-time `x-ratelimit-remaining-tokens` drives P2 routing. Best per-minute alignment with PTU windows. | ⭐⭐⭐⭐⭐ Highest for async P2 (95%+) — Queue fills ALL idle PTU capacity. But P2 must be async. Monitoring lag mitigated by threshold buffers + queue smoothing. See GenAI Playbook deep-dive above. | ⭐⭐⭐⭐⭐ Highest (85-95%) — Preemptive priority queue + real-time response headers + circuit breaker. P1 always served first, P2 fills remaining PTU. |
| **Priority Guarantee** | ⭐⭐⭐⭐ Strong — Static reservation guarantees prod headroom. But headroom is wasted when unused. | ⭐⭐ Weak — Both tiers compete equally. No priority during contention. | ⭐⭐⭐⭐ Strong — P2 redirected to PAYG when PTU is busy. Cache staleness may cause brief overlap. | ⭐⭐⭐⭐⭐ Strongest — P1 is always synchronous/direct. P2 is queued and metered. | ⭐⭐⭐⭐⭐ Strongest — True priority queue. P1 always first. |
| **Solution Complexity** | ⭐⭐⭐⭐⭐ Lowest — Proven Citadel IaC pattern. JSON contracts → Bicep → done. | ⭐⭐⭐⭐⭐ Lowest — Same as Option 1, just different TPM numbers. | ⭐⭐⭐ Medium — ~200 lines of custom C# in APIM XML policy. Based on deprecated AI-Gateway pattern. Requires testing. | ⭐⭐ High — Event Hub + orchestration service (Function/Container App) + Stream Analytics or Azure Monitor integration. Multiple moving parts. | ⭐⭐⭐ Medium — Microsoft-maintained open-source. Deploy ACA + install APIM policy. Config, not code. |
| **Development Effort** | ⭐⭐⭐⭐⭐ Days — Mostly config. Extend Citadel access contracts. | ⭐⭐⭐⭐⭐ Days — Same as Option 1. | ⭐⭐⭐ 1-2 weeks — Custom policy development + testing. | ⭐⭐ 2-4 weeks — Orchestrator service + monitoring integration + queue consumer. | ⭐⭐⭐ 1-2 weeks — Deploy ACA, configure user profiles + backends. Ships with APIM policy. |
| **Maintenance** | ⭐⭐⭐⭐⭐ Minimal — APIM-native policies. Microsoft-maintained. | ⭐⭐⭐⭐⭐ Minimal — Same as Option 1. | ⭐⭐⭐ Medium — Custom policy must be maintained. APIM policy updates may break custom C#. | ⭐⭐ High — Orchestrator code, Event Hub, Stream Analytics all need maintenance + monitoring. | ⭐⭐⭐ Medium — Microsoft-maintained repo. Container runtime + config updates. |
| **HA/DR Support** | ⭐⭐⭐⭐⭐ Native — APIM multi-region, backend pool failover, circuit breaker. All built-in. | ⭐⭐⭐⭐⭐ Native — Same as Option 1. | ⭐⭐⭐⭐ Good — APIM-native HA. Cache state is per-gateway instance (may diverge in multi-region). | ⭐⭐⭐ Moderate — Event Hub has geo-DR. Orchestrator needs its own HA (multiple instances + coordination). Stream Analytics SLA. | ⭐⭐⭐ Moderate — ACA multi-replica. In-memory priority queue (not shared across replicas). Circuit breaker per instance. |
| **Latency Impact** | ⭐⭐⭐⭐⭐ None — Direct APIM passthrough. | ⭐⭐⭐⭐⭐ None — Same. | ⭐⭐⭐⭐ Minimal — ~1-5ms for cache lookup + routing logic in APIM. | ⭐⭐ Significant for P2 — P1 is direct (no impact). P2 adds queue latency (seconds to minutes depending on PTU load). Not suitable for synchronous chat. | ⭐⭐⭐⭐ Low — Extra hop ~5-20ms. Under load, P2 waits (seconds) while P1 is prioritized. Streaming supported. |
| **Requires APIM Subscriptions (API Keys)** | ✅ Yes — `llm-token-limit counter-key` uses `Subscription.Id`. Products require subscription keys. Can use JWT for **auth** while keeping subscription keys for **routing** (ai-gw-v2 pattern). | ✅ Yes — Same as Option 1. | ⚠️ Optional — Can use JWT claims (`oid`, app roles) as counter-key and priority classifier instead of subscriptions. Enables fully keyless operation but requires `<choose>` blocks for per-identity policy. | ❌ No — Classification via header or JWT claim. Queue consumer uses its own identity. No subscription keys needed. | ❌ No — Uses custom `userId` header from user profiles. APIM handles auth upstream. |
| **Sync/Async** | Sync | Sync | Sync | P1: Sync, P2: Async | Sync + Async (opt-in per request/user) |
| **Works with Foundry Agents** | ✅ Yes — Native APIM integration | ✅ Yes | ✅ Yes — Same APIM surface | ⚠️ P2 only if agents support async | ✅ Yes — Transparent proxy (sync mode) |

---

## Deployment Topologies

The priority routing options above (Options 1–5) are **logical patterns** — they can be deployed across different physical topologies. This section covers two deployment models: single-region (simpler, lower cost) and multi-region (HA/DR, lower latency).

---

### Topology A: Single-Region

**Best for:** MVP, cost-sensitive workloads, single-geography teams, initial Citadel rollout.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Azure Region (e.g., West Europe)                                    │
│                                                                      │
│  ┌─────────────────────────────────────┐                             │
│  │  VNet                                │                             │
│  │                                      │                             │
│  │  ┌──────────────────────┐            │                             │
│  │  │  App Gateway (WAF)   │◄── Clients │                             │
│  │  │  (public IP)         │            │                             │
│  │  └──────────┬───────────┘            │                             │
│  │             │                        │                             │
│  │  ┌──────────▼───────────┐            │  ┌──────────────────────┐  │
│  │  │  APIM (Internal VNet)│            │  │  Azure OpenAI (PTU)  │  │
│  │  │  - Priority policies │───────────────►  Private Endpoint    │  │
│  │  │  - Token limits      │            │  └──────────────────────┘  │
│  │  │  - Circuit breaker   │            │                             │
│  │  └──────────┬───────────┘            │  ┌──────────────────────┐  │
│  │             │ (PAYG spillover)       │  │  Azure OpenAI (PAYG) │  │
│  │             └───────────────────────────►  Private Endpoint    │  │
│  │                                      │  └──────────────────────┘  │
│  └─────────────────────────────────────┘                             │
│                                                                      │
│  Optional: ACA with YARP (for Option 5)                              │
│  ┌─────────────────────┐                                             │
│  │  Container Apps Env  │  Sits between App GW and APIM or           │
│  │  - YARP proxy        │  replaces APIM entirely for routing        │
│  │  - Priority queue    │                                             │
│  └─────────────────────┘                                             │
└──────────────────────────────────────────────────────────────────────┘
```

**Multi-region OpenAI backends (single-region APIM):**
Even with a single-region APIM, you can route to **OpenAI deployments in multiple regions** via APIM backend pools. This is how ai-gw-v2 works — one APIM instance with backend pools that have priority 1 (primary region), priority 2 (secondary), priority 3 (tertiary). Circuit breaker on 429 trips to next-priority backend.

```bicep
// Example: Backend pool with multi-region priority
resource backendPool 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  name: 'pool-gpt-5-2-chat'
  properties: {
    type: 'Pool'
    pool: {
      services: [
        { id: '/backends/aoai-westeurope'   priority: 1  weight: 1 }  // PTU (primary)
        { id: '/backends/aoai-northeurope'  priority: 2  weight: 1 }  // PAYG (spillover)
        { id: '/backends/aoai-eastus'       priority: 3  weight: 1 }  // PAYG (DR)
      ]
    }
  }
}
```

**Key characteristics:**
- APIM tier: Standard v2 or Premium v2 (Premium v2 for VNet injection)
- Single point of failure: APIM region outage = complete outage
- Latency: All requests go through one region regardless of caller location
- Cost: ~$300-700/mo for APIM Premium v2 (1 unit)
- OpenAI: Can span regions via backend pools (failover only, not load balancing across regions simultaneously)

---

### Topology B: Multi-Region HA

**Best for:** Production-critical workloads, multi-geography teams, SLA requirements >99.95%.

There are **three viable patterns** for multi-region, each with different trade-offs for private networking:

#### Pattern B1: APIM Premium Multi-Region (Recommended for private traffic)

APIM Premium (classic or v2) natively supports multi-region deployment — one logical instance with gateway nodes in multiple regions.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                                                                                  │
│  ┌───────────────────┐      ┌───────────────────┐      ┌───────────────────┐    │
│  │  Region: West EU   │      │  Region: North EU  │      │  Region: East US  │    │
│  │                    │      │                    │      │                    │    │
│  │  ┌──────────────┐ │      │  ┌──────────────┐ │      │  ┌──────────────┐ │    │
│  │  │ APIM Gateway │ │      │  │ APIM Gateway │ │      │  │ APIM Gateway │ │    │
│  │  │ (regional)   │ │      │  │ (regional)   │ │      │  │ (regional)   │ │    │
│  │  └──────┬───────┘ │      │  └──────┬───────┘ │      │  └──────┬───────┘ │    │
│  │         │         │      │         │         │      │         │         │    │
│  │  ┌──────▼───────┐ │      │  ┌──────▼───────┐ │      │  ┌──────▼───────┐ │    │
│  │  │ OpenAI (PTU) │ │      │  │ OpenAI (PAYG)│ │      │  │ OpenAI (PAYG)│ │    │
│  │  │ Pvt Endpoint │ │      │  │ Pvt Endpoint │ │      │  │ Pvt Endpoint │ │    │
│  │  └──────────────┘ │      │  └──────────────┘ │      │  └──────────────┘ │    │
│  └───────────────────┘      └───────────────────┘      └───────────────────┘    │
│                                                                                  │
│  Routing: Azure Traffic Manager (DNS-based) OR custom DNS                        │
│  Management plane: Primary region only (West EU)                                 │
│  Policies: Replicated to all regional gateways automatically                     │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Private traffic routing:**
- Each regional APIM gateway is deployed in Internal VNet mode within that region's VNet
- **Traffic Manager CANNOT route to private endpoints** — it only works with public IPs
- For private multi-region routing, options are:
  - **ExpressRoute/VPN + custom DNS**: Clients on-prem or in Azure VNets resolve APIM to nearest regional private IP via Azure Private DNS zones linked across VNets/hubs
  - **Hub-spoke with peering**: Each region has a hub VNet with APIM; spokes peer to the hub; cross-region peering or Global VNet Peering connects the hubs
  - **Internal load balancer per region**: Clients route via private IPs; health probes handled internally
- Cost: APIM Premium v2 multi-region (~$700+/mo per additional region unit)

#### Pattern B2: Azure Front Door Premium + APIM (Best for public + private hybrid)

Front Door Premium supports **Private Link origins** — it can connect to APIM's private endpoint over Azure's backbone while serving clients globally.

```
                    ┌─────────────────┐
  Clients ─────────►│  Azure Front    │
  (public internet) │  Door Premium   │
                    │  - WAF          │
                    │  - Global LB    │
                    │  - SSL offload  │
                    └────────┬────────┘
                             │ Private Link
                    ┌────────▼────────┐
                    │  APIM (region 1)│
                    │  Private EP     │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  OpenAI (PTU)   │
                    │  Private EP     │
                    └─────────────────┘
```

**Key considerations:**
- ✅ Traffic from Front Door to APIM is **fully private** (Private Link over Azure backbone)
- ✅ Front Door provides global anycast, DDoS protection, WAF, SSL termination
- ⚠️ Front Door itself is a **public-facing** service — clients connect over the internet
- ⚠️ APIM Premium v2 is **NOT supported** as a Front Door Private Link origin (as of early 2026) — must use classic APIM v1 (Developer, Basic, Standard, Premium) OR use Front Door → Application Gateway → APIM internal
- ❌ Does NOT keep client-to-Front-Door traffic private — only Front-Door-to-APIM is private
- For **fully private end-to-end**: Front Door is NOT the right choice. Use Pattern B1 or B3.

#### Pattern B3: Application Gateway per Region + Custom DNS (Fully private)

For **zero public exposure** — no public IPs anywhere:

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  On-prem / Azure clients (via ExpressRoute or VPN)                  │
  │                                                                     │
  │  Custom DNS / Azure Private DNS ──► Nearest region by latency       │
  │                                                                     │
  │  Region 1 (West EU)              Region 2 (North EU)                │
  │  ┌───────────────────┐           ┌───────────────────┐              │
  │  │  App GW (internal) │           │  App GW (internal) │              │
  │  │  Private IP only   │           │  Private IP only   │              │
  │  └────────┬──────────┘           └────────┬──────────┘              │
  │           │                               │                         │
  │  ┌────────▼──────────┐           ┌────────▼──────────┐              │
  │  │  APIM (Internal)   │           │  APIM (Internal)   │              │
  │  └────────┬──────────┘           └────────┬──────────┘              │
  │           │                               │                         │
  │  ┌────────▼──────────┐           ┌────────▼──────────┐              │
  │  │  OpenAI (PTU)      │           │  OpenAI (PAYG)     │              │
  │  │  Private EP        │           │  Private EP        │              │
  │  └───────────────────┘           └───────────────────┘              │
  └─────────────────────────────────────────────────────────────────────┘
```

**How is traffic routed to the right region?**

Azure Private DNS zones do NOT support geo/latency-based routing — they simply return A records. You need one of these approaches:

1. **Regional Private DNS zones** — Create separate Private DNS zones per region, each linked only to that region's VNet. Clients in West EU VNet resolve `api.contoso.internal` → West EU App GW private IP. Clients in North EU VNet → North EU App GW private IP. Simple, but no cross-region failover unless you automate A record updates.

2. **Azure DNS Private Resolver with conditional forwarding** — Deploy a Private Resolver in each region's hub VNet. On-prem DNS forwards to the nearest resolver (primary/secondary). Doesn't provide latency-based routing, but provides DNS-level failover if a resolver is down.

3. **Automation-based failover (cross-region monitoring)** — Each region's Function App monitors the OTHER region. When Region A detects Region B is down, Region A's Function updates the Private DNS zone to redirect Region B's traffic to Region A (and vice versa).

   ```
   ┌───────────────────────────┐         ┌───────────────────────────┐
   │  Region 1 (West EU)       │         │  Region 2 (North EU)      │
   │                           │         │                           │
   │  App GW → APIM → OpenAI   │         │  App GW → APIM → OpenAI   │
   │                           │         │                           │
   │  ┌─────────────────────┐  │  probes │  ┌─────────────────────┐  │
   │  │ Function App        │──┼────────►│  │ /health endpoint    │  │
   │  │ "Monitor Region 2"  │  │         │  └─────────────────────┘  │
   │  │                     │  │         │                           │
   │  │ On failure:         │  │         │  ┌─────────────────────┐  │
   │  │ Update DNS zone     │  │  probes │  │ Function App        │  │
   │  │ R2 → R1 private IP  │  │◄────────┼──│ "Monitor Region 1"  │  │
   │  └─────────────────────┘  │         │  │                     │  │
   │                           │         │  │ On failure:         │  │
   │  ┌─────────────────────┐  │         │  │ Update DNS zone     │  │
   │  │ Azure Monitor       │  │         │  │ R1 → R2 private IP  │  │
   │  │ Alert → Function    │  │         │  └─────────────────────┘  │
   │  └─────────────────────┘  │         │                           │
   └───────────────────────────┘         └───────────────────────────┘
                        │                           │
                        └───────────┬───────────────┘
                                    │
                         ┌──────────▼──────────┐
                         │  Shared Private DNS  │
                         │  Zone (linked to     │
                         │  both VNets)         │
                         └─────────────────────┘
   ```

   **How the cross-monitoring works:**
   - Region 1's Function probes Region 2's App GW `/health` endpoint over VNet peering (private, no public exposure)
   - If Region 2 fails 3 consecutive probes (e.g., 30s interval), Region 1's Function updates the Private DNS A record for Region 2's FQDN to point to Region 1's App GW private IP
   - Region 2's Function does the mirror — monitors Region 1, fails over to Region 2
   - **Split-brain prevention**: Use a shared state store (e.g., Cosmos DB multi-region or Storage Account with blob lease) so both Functions agree on who is primary
   - **Recovery**: When the failed region comes back, the monitoring Function detects health restored → updates DNS back to original IPs (or keeps failover until manual confirmation)
   - **Failover delay**: Health check interval (30s) × failure threshold (3) + DNS TTL (60s) = ~2.5 min

   > ⚠️ **Control-plane HA risk**: The failover automation itself must survive region failures. This is why each region monitors the OTHER — if Region 1 goes down, Region 2's Function is still alive to perform the DNS update. However, if BOTH regions fail simultaneously (rare but possible), failover breaks. For this edge case, consider a third "control plane" region with a lightweight Function that monitors both.

4. **Traffic Manager + split-horizon DNS** — See detailed pattern below.

**Key characteristics:**
- ✅ Fully private end-to-end — no public IPs, no internet exposure
- ✅ Works with ExpressRoute, VPN, or Azure-to-Azure private peering
- ⚠️ No built-in latency-based routing for private DNS — must use regional zones or automation
- ⚠️ Failover automation requires cross-region monitoring (each region watches the other) + shared state for split-brain prevention
- ⚠️ Failover delay ~2-3 min (probe interval × threshold + DNS TTL)
- ⚠️ Operational complexity: Two APIM instances + Function Apps + health probes + DNS automation

---

### Topology Comparison

| Criteria | Topology A: Single-Region | B1: APIM Multi-Region | B2: Front Door + APIM | B3: App GW per Region | B4: TM + App GW dual-IP |
|---|---|---|---|---|---|
| **HA/DR** | ❌ Single point of failure | ✅ Automatic regional failover | ✅ Global failover via Front Door | ⚠️ Automated DNS failover (needs scripting) | ✅ TM automatic failover (30-60s) |
| **Fully Private Traffic** | ✅ Internal VNet mode | ✅ Internal VNet + private DNS | ⚠️ Client→AFD is public; AFD→APIM is private | ✅ Fully private end-to-end | ✅ API traffic fully private (public IP only for /health) |
| **Traffic Manager Compatible** | N/A (single region) | ⚠️ Yes with split-horizon DNS | ✅ TM can route to Front Door (public) | ⚠️ Yes with split-horizon DNS | ✅ Native — TM probes public IP, traffic uses private IP |
| **Global Latency** | ❌ All traffic to one region | ✅ Regional gateways | ✅ Anycast edge | ✅ Regional App GWs | ✅ TM latency-based routing to nearest region |
| **APIM Tier Required** | Standard v2 / Premium v2 | Premium (classic or v2) | Classic (not Premium v2 for PL origin) | Premium (classic or v2) | Any tier (App GW is entry point) |
| **Cost** | 💰 Low (~$300-700/mo APIM) | 💰💰💰 High (~$700/mo per region) | 💰💰 Medium (AFD + APIM) | 💰💰💰 High (App GW + APIM per region) | 💰💰💰 High (TM + App GW + APIM per region) |
| **Complexity** | ⭐⭐⭐⭐⭐ Lowest | ⭐⭐⭐ Medium | ⭐⭐⭐ Medium | ⭐⭐ High | ⭐⭐⭐ Medium (no custom automation) |
| **Works with Option 5 (SimpleL7Proxy)** | ✅ ACA in same VNet | ✅ ACA per region | ✅ ACA behind APIM | ✅ ACA per region | ✅ ACA per region |

### Traffic Manager + Private Endpoints: The Split-Horizon DNS Pattern

**Direct answer: Traffic Manager cannot route to private IPs natively.** TM is DNS-based and returns public FQDNs/IPs. Its health probes originate from public Azure infrastructure and cannot reach private endpoints.

**However**, you can use Traffic Manager for the **routing decision** while split-horizon DNS handles **address resolution**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  1. Client queries:  api.contoso.com                                        │
│                        │                                                    │
│  2. Public DNS returns: api.contoso.com → CNAME → myapi.trafficmanager.net  │
│                        │                                                    │
│  3. Traffic Manager evaluates (latency/priority/weighted):                  │
│     Returns: myapi.trafficmanager.net → CNAME → apim-westeu.contoso.com    │
│                        │                                                    │
│  4. Client resolves apim-westeu.contoso.com:                                │
│     ┌────────────────────────────────────────┐                              │
│     │ On corporate network (split-horizon):  │                              │
│     │ Private DNS zone resolves to 10.0.1.5  │ ← Private IP of App GW/APIM │
│     │ Client connects via ExpressRoute/VPN   │                              │
│     ├────────────────────────────────────────┤                              │
│     │ From internet (if allowed):            │                              │
│     │ Public DNS resolves to public IP       │                              │
│     │ (or NXDOMAIN if no public record)      │                              │
│     └────────────────────────────────────────┘                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**How it works:**
1. Client asks DNS for `api.contoso.com`
2. Gets CNAME chain through Traffic Manager → TM picks the best region (e.g., `apim-westeu.contoso.com`)
3. Client resolves `apim-westeu.contoso.com`
4. **On corporate network**: Azure Private DNS zone (or on-prem DNS with conditional forwarders) resolves to the **private IP** of the regional App GW / APIM
5. **From internet**: Public DNS resolves to public IP (or returns nothing if fully private)

**The catch — health probes:**
- Traffic Manager health probes come from public Azure IPs and CANNOT reach private endpoints
- **Recommended: App Gateway with dual IPs (public health + private data)** — See Pattern B4 below
- **Workaround 1: "Always Serve" mode** — Set TM endpoints to `Always Serve = Enabled`. TM always returns the endpoint in DNS responses regardless of health. Combine with **application-level health monitoring** (Azure Monitor alerts → Azure Functions to disable TM endpoint on failure).
- **Workaround 2: Nested profiles** — Use TM priority routing with "Always Serve" for normal operation + manual endpoint disable during DR events.

#### Pattern B4: Traffic Manager + App Gateway (Public Health, Private Data) — Recommended Hybrid

This pattern exploits the fact that **Application Gateway has both a public IP and a private IP**:
- TM health probes hit the **public IP** (only `/health` exposed)
- Internal clients resolve to the **private IP** via split-horizon DNS
- API traffic flows entirely privately: Client → App GW (private IP) → APIM (internal) → OpenAI (private endpoint)

```
                    ┌─────────────────────────┐
                    │   Traffic Manager        │
                    │   (DNS routing:          │
                    │    latency/priority)     │
                    └─────────┬───────────────┘
                              │ Health probes (public)
                              │ Returns CNAME: appgw-westeu.contoso.com
                              │
           ┌──────────────────┼──────────────────────┐
           │                  │                       │
   Region 1 (West EU)        │              Region 2 (North EU)
   ┌──────────────────────┐   │              ┌──────────────────────┐
   │                      │   │              │                      │
   │  App Gateway         │   │              │  App Gateway         │
   │  ┌────────────────┐  │   │              │  ┌────────────────┐  │
   │  │ Public IP ◄────┼──┼───┘ (health     │  │ Public IP ◄────┼──┘ (health
   │  │ /health only   │  │      probe)      │  │ /health only   │    probe)
   │  ├────────────────┤  │                  │  ├────────────────┤  │
   │  │ Private IP ◄───┼──┼─── Client       │  │ Private IP ◄───┼── Client
   │  │ 10.1.0.5       │  │    (ExpressRoute │  │ 10.2.0.5       │   (ExpressRoute
   │  │ All API traffic │  │     or VPN)     │  │ All API traffic │    or VPN)
   │  └───────┬────────┘  │                  │  └───────┬────────┘  │
   │          │            │                  │          │            │
   │  ┌───────▼────────┐  │                  │  ┌───────▼────────┐  │
   │  │ APIM (Internal) │  │                  │  │ APIM (Internal) │  │
   │  └───────┬────────┘  │                  │  └───────┬────────┘  │
   │          │            │                  │          │            │
   │  ┌───────▼────────┐  │                  │  ┌───────▼────────┐  │
   │  │ OpenAI (PTU)    │  │                  │  │ OpenAI (PAYG)   │  │
   │  │ Private EP      │  │                  │  │ Private EP      │  │
   │  └────────────────┘  │                  │  └────────────────┘  │
   └──────────────────────┘                  └──────────────────────┘

   DNS Resolution (split-horizon):
   ┌─────────────────────────────────────────────────────────────────┐
   │ Public DNS:  appgw-westeu.contoso.com → 52.x.x.x (public IP)  │
   │ Private DNS: appgw-westeu.contoso.com → 10.1.0.5 (private IP) │
   └─────────────────────────────────────────────────────────────────┘
```

**How it works step-by-step:**

1. **TM health probes** → hit App GW's **public IP** → App GW responds to `/health` → TM marks region healthy/unhealthy
2. **TM DNS routing** → client queries `api.contoso.com` → TM returns CNAME `appgw-westeu.contoso.com` (best region)
3. **Client DNS resolution** → on corporate network, Private DNS zone resolves `appgw-westeu.contoso.com` → **10.1.0.5** (private IP)
4. **API traffic** → Client connects to 10.1.0.5 (private) → App GW → APIM (internal VNet) → OpenAI (private endpoint)
5. **If region fails** → TM probes detect unhealthy → TM returns `appgw-northeu.contoso.com` instead → client resolves to 10.2.0.5

**Security hardening of the public IP:**
- App GW's public listener **only** exposes `/health` — a simple 200 OK endpoint
- NSG on App GW subnet restricts public IP access to [Azure Traffic Manager probe IPs](https://learn.microsoft.com/en-us/azure/traffic-manager/traffic-manager-faqs#what-ip-addresses-does-traffic-manager-use-for-health-probes) only
- WAF on App GW blocks everything except the health probe path
- All API paths return 403 on the public listener — API traffic only accepted on private listener
- Effectively: public IP exists for TM probing only, attack surface is minimal

**⚠️ Requires split-horizon DNS (split DNS) — non-trivial setup:**

This pattern depends on **split-horizon DNS** (also called split DNS or split-brain DNS): the same FQDN resolving to different IPs depending on where the query originates. This is a well-known enterprise DNS pattern but requires careful coordination across multiple DNS layers:

| DNS Layer | Configuration Required |
|---|---|
| **Public DNS zone** (e.g., Azure DNS public) | `appgw-westeu.contoso.com` → A record → App GW **public IP** (52.x.x.x). This is what TM health probes and external DNS see. |
| **Azure Private DNS zone** (linked to hub VNets) | `appgw-westeu.contoso.com` → A record → App GW **private IP** (10.1.0.5). This overrides public DNS for clients inside linked VNets. |
| **On-prem DNS** (if ExpressRoute/VPN clients) | Conditional forwarder for `contoso.com` → Azure DNS Private Resolver inbound endpoint. Ensures on-prem clients resolve via Private DNS zones. |
| **Azure DNS Private Resolver** (per region hub) | Inbound endpoint in hub VNet. Receives forwarded queries from on-prem, resolves via linked Private DNS zones. |
| **Traffic Manager profile** | `api.contoso.com` → CNAME → `myapi.trafficmanager.net`. External endpoints pointing to `appgw-westeu.contoso.com` and `appgw-northeu.contoso.com`. |

**What can go wrong:**
- **DNS caching**: If a client caches the public IP and then connects from a private network (or vice versa), requests go to the wrong frontend. Set low TTLs (60s) and ensure DNS resolver selection is correct.
- **Private DNS zone not linked**: If a VNet isn't linked to the Private DNS zone, clients in that VNet resolve the public IP → traffic goes over the internet instead of privately.
- **On-prem conditional forwarder misconfiguration**: If on-prem DNS doesn't forward to Private Resolver, on-prem clients resolve public IP → traffic exits over internet before coming back through ExpressRoute (hairpin).
- **Multiple Private DNS zones**: If you have zones in different subscriptions or regions, ensure they all have the correct A records and VNet links.
- **App GW listener mismatch**: App GW needs separate listeners for public and private frontends, even if they use the same hostname. Requests arriving on the wrong frontend may not match any routing rule.

**Validated**: App Gateway v2 natively supports up to 4 frontend IPs (public IPv4, private IPv4, public IPv6, private IPv6) on the same instance. Public and private listeners can use the same hostname and same backend pool, or different rules per frontend (recommended — restrict public to `/health` only).

**Why this works better than alternatives:**

| Aspect | B4 (TM + App GW dual-IP) | B1 (APIM multi-region) | B3 (custom DNS failover) |
|--------|--------------------------|------------------------|--------------------------|
| **Health probes** | ✅ TM automatic (public IP) | ✅ Built-in | ❌ Custom automation |
| **Routing intelligence** | ✅ TM latency/priority/weighted | ⚠️ Nearest gateway only | ❌ Static per-VNet |
| **Private data plane** | ✅ All API traffic on private IP | ✅ Internal VNet | ✅ Fully private |
| **Failover time** | ~30-60s (TM probe + DNS TTL) | ~seconds (built-in) | ~2-3 min (automation delay) |
| **Public surface** | ⚠️ Minimal: `/health` only, NSG-restricted | ✅ None | ✅ None |
| **Cost** | App GW + APIM per region | APIM Premium per region | App GW + APIM per region |
| **APIM tier** | Any (App GW is the entry point) | Premium only | Premium for multi-region |

**Is this worth the complexity?**

| Approach | Routing Intelligence | Health Probes | Complexity |
|----------|---------------------|---------------|------------|
| TM + split-horizon + Always Serve | ✅ Latency/priority/weighted | ❌ None (manual failover) | Medium |
| TM + split-horizon + public health EP | ✅ Latency/priority/weighted | ✅ Automatic via public probe | Medium-High |
| APIM multi-region (B1) | ✅ Built-in (nearest gateway) | ✅ Built-in | Low |
| Regional Private DNS zones | ❌ Static (per-VNet) | ❌ Manual failover | Low |

**Verdict**: If you're already paying for APIM Premium (required for multi-region), **Pattern B1 is simpler** — APIM handles regional routing natively. The TM + split-horizon pattern is most useful when:
- You have non-APIM components that also need multi-region routing
- You want latency-based routing across regions (APIM multi-region doesn't do this — it routes to nearest gateway by client IP, which is similar but not identical)
- You want to use a single global FQDN that resolves to private IPs in different regions

---

## Recommendation

### For most customers: **Start with Option 1 (Citadel), evolve to Option 3 if needed**

**Phase 1 — Citadel Access Contracts (Option 1)**
- Deploy immediately using proven Citadel IaC pattern
- Set initial TPM allocations with moderate oversubscription:
  - Prod: 90% of PTU TPM
  - Dev/Test: 50% of PTU TPM (total: 140% — safe oversubscription)
- Monitor actual usage via App Insights token metrics for 2-4 weeks
- Track PTU utilization % and PAYG spillover rate per product

**Phase 2 — Evaluate and tune (week 2-4)**
- If PTU utilization > 70% and prod PAYG spillover < 5% → **stay on Option 1** (it's working)
- If PTU utilization < 60% → increase dev/test TPM allocation
- If prod frequently spills to PAYG while dev/test doesn't → decrease dev/test, increase prod

**Phase 3 — Upgrade to Option 3 if needed**
- If monitoring shows PTU utilization is consistently low AND you can't solve it with allocation tuning
- Implement the custom priority-aware APIM policy
- This gives dynamic utilization without the complexity of Event Hub or YARP

### When to choose Option 4 (Event Hub Queue):
- You have **async/batch workloads** where P2 latency doesn't matter
- PTU capacity is very expensive and utilization must be >90%
- You have the team to build and maintain the orchestration service

### When to choose Option 5 (SimpleL7Proxy):
- You need **true priority queuing** where P1 always preempts P2 (not just routing decisions)
- You have **mixed sync + async workloads** (interactive chat + batch processing)
- You want a **Microsoft-maintained** solution with a production APIM policy included
- You need **per-user fair-share governance** (prevent noisy neighbors)
- Your team can operate Azure Container Apps
- **Strong alternative to Option 3**: Similar PTU utilization but with true queuing instead of just per-request routing. More complex to deploy, but more capable.

---

## Implementation Plan (Phase 1 — Citadel)

### Todo 1: Document architecture decision
Create an ADR covering the chosen phased approach, comparison table, and rationale.

### Todo 2: Create Citadel access contracts
Define access contract JSONs for each subscriber tier:
- `prod-priority-contract.json` — P1, higher TPM (90% of PTU)
- `devtest-priority-contract.json` — P2, moderate TPM (50% of PTU)
- Include model access, capacity management, and usage tracking
- Reference: `ai-hub-gateway-solution-accelerator/bicep/infra/citadel-access-contracts/`

### Todo 3: Configure backend pool (PTU + PAYG)
Bicep backend pool config:
- PTU backend: `priority: 1`, `weight: 100`
- PAYG backend: `priority: 2`, `weight: 100`
- Circuit breaker: 3 failures in 10s → 10s trip, `acceptRetryAfter: true`

### Todo 4: Deploy and validate
- Deploy via Citadel Bicep (`az deployment sub create`)
- Validate with concurrent requests using both subscription keys
- Confirm prod gets PTU, dev/test spills to PAYG under load

### Todo 5: Set up monitoring
- App Insights dashboard: token consumption per product, PTU utilization %, PAYG spillover rate
- Alerts: PTU utilization <50% sustained, prod PAYG spillover >10%

### Todo 6: (Phase 3, if needed) Custom priority-aware APIM policy
- Implement dynamic routing based on cached PTU utilization
- Based on `AI-Gateway/labs/_deprecated/advanced-load-balancing/policy.xml`
- Add subscriber priority awareness from Product context

---

## Key Configuration Parameters

| Parameter | Description | Prod (P1) | Dev/Test (P2) |
|-----------|-------------|-----------|----------------|
| `tokensPerMinute` | TPM limit per subscription | 90% of PTU TPM | 50% of PTU TPM |
| `tokenQuota` | Monthly token budget | Higher/unlimited | Lower |
| `tokenQuotaPeriod` | Quota reset period | Monthly | Monthly |
| Backend `priority` | Pool routing priority | 1 (PTU), 2 (PAYG) | 1 (PTU), 2 (PAYG) |
| Circuit breaker trip | Failures before trip | 3 in 10s | 3 in 10s |
| Circuit breaker recovery | Auto-recovery time | 10s | 10s |

**Tuning guidance:**
- Start with 90%/50% split (140% oversubscription)
- Total oversubscription up to ~200% is generally safe — circuit breaker + PAYG catches overflow
- Monitor for 2-4 weeks before adjusting
- Key metric: prod PAYG spillover rate should be <5%
