# TODO — AI Gateway with Access Contracts + Priority Routing

> For FinOps comparison analysis and APIM data pipeline limitations, see [docs/architecture-plan.md](docs/architecture-plan.md#finops-token-counting--chargeback-approaches).

## 1. Scaling to More Clients

**Status:** ✅ Implemented (access contracts in blob storage)

Access contracts are stored as JSON in Azure Blob Storage (cached 5 min in APIM), removing the Named Value pair limit. Identity matching supports multiple claim types (`azp`, `appid`, `xms_mirid`, `oid`, `sub`) with prefix matching.

- [ ] Load test with 100+ contracts in blob storage

## 2. Multi-Deployment Routing

**Status:** ✅ Implemented

Per-model backend pools (`{model}-ptu-pool`, `{model}-payg-pool`) with priority routing. P1 → PTU first (PAYG failover on 429), P2/P3 → PAYG. Circuit breaker handles backend failures.

## 3. Monthly Quota Notifications

**Status:** Event Hub notification done. Email not started.

- [ ] Notify teams when their monthly token budget is approaching the limit (e.g., at 80% and 90% thresholds)
- [ ] Evaluate notification channels: email, Teams webhook, or Azure Monitor action groups
- [ ] Add threshold-based KQL alerts in addition to the existing over-budget alert

## 5. Per Consumer Configuration

**Status:** ✅ Implemented (access contracts with per-team models, quotas, and priority)

Access contracts define per-team configuration: allowed models, per-model TPM limits, PTU allocations, monthly token budgets, and routing priority. Contracts are defined in `main.bicepparam` and compiled to blob storage at deploy time.

- [ ] Self-service UI for APIM ops team to manage contracts without redeploying

## 6. Virtual Quotas for PTU

**Status:** ✅ Implemented

Each team's access contract specifies `ptuTpm` per model — a soft PTU allocation enforced via `llm-token-limit` in the PTU Gate loopback API. When exceeded, requests overflow to PAYG automatically.

## 7. Chargeback - FinOps

Have reports that show how many tokens were used from a given deployment and their cost.

- [ ] Dashboard to show cost per team
- [ ] PTU deployment should track free requests (cache used) and specify how much PTU deployment was consumed

### Reference Implementations

- [APIM OpenAI Chargeback](https://github.com/andyogah/apim-openai-chargeback-environment)
- [AI Gateway FinOps](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/finops-framework/finops-framework.ipynb)
- [Citadel Power BI Report](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/citadel-v1/guides/power-bi-dashboard.md)
- [APIM ChargeBack](https://github.com/seiggy/apim-chargeback)
- [ai-policy-engine](https://github.com/Azure-Samples/ai-policy-engine) — ASP.NET 10 + APIM with per-tenant billing (Redis + CosmosDB), React dashboard, billing modes (token/multiplier/hybrid)

### Reference Comparison: Token Counting & FinOps Approaches

| | [AI-Gateway FinOps Lab](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/finops-framework) | [Citadel AI Hub Gateway](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) | [APIM Chargeback (seiggy)](https://github.com/seiggy/apim-chargeback) | [APIM OpenAI Chargeback (andyogah)](https://github.com/andyogah/apim-openai-chargeback-environment) | [llm-token-limit (APIM native)](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy) |
|---|---|---|---|---|---|
| **Token counting method** | `azure-openai-emit-token-metric` — native APIM policy emits token metrics to Azure Monitor | Triple approach: (1) `llm-emit-token-metric` for metrics, (2) response body parsing for detailed counts, (3) `azure-openai-emit-token-metric` for streaming | APIM outbound policy extracts `usage` from response body, sends to external ASP.NET API (`/api/log`) | APIM outbound policy sends full response payload to Azure Function (Python) via `send-request` | Internal to APIM — counts tokens from LLM response `usage` field; optionally estimates prompt tokens before forwarding |
| **Data pipeline reliability** | ⚠️ **At risk** — `emit-token-metric` sends custom metrics to **App Insights**, which is subject to [sampling, throttling, and a 50K active time series limit](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-limits). High-cardinality dimensions (per-user, per-team) can exhaust the limit quickly. Metrics may be silently dropped under load. Not suitable as system of record for billing. **Better alternative:** Use built-in `ApiManagementGatewayLlmLog` (Log Analytics) — reliable, not sampled, captures prompt/completion tokens per request with ~5 min delay | ⚠️ **Mixed** — `llm-emit-token-metric` has same App Insights throttling risk. However, the `log-to-eventhub` pipeline is durable (EventHub guarantees delivery) and serves as the reliable path for cost calculation. **Recommendation:** treat emit-metric as dashboards-only; EventHub for billing | ✅ **Reliable** — direct HTTP POST to external API on every request. No dependency on App Insights ingestion. Data goes straight to Redis/Cosmos DB. Trade-off: adds latency per request | ✅ **Reliable** — `send-request` to Azure Function on every request. No App Insights dependency. Trade-off: adds 50-200ms latency per request | ✅ **Reliable for enforcement** — internal counters are in-memory, not subject to external throttling. However, counters are per-gateway (not shared across regions) and not persisted — no audit trail |
| **Built-in LLM logs (`ApiManagementGatewayLlmLog`)** | Not used — relies entirely on `emit-token-metric` to App Insights | Not used — relies on `emit-token-metric` + EventHub | Not used — external API approach | Not used — external Function approach | N/A — built-in logs are the **most reliable** option for token tracking. Sent to Azure Monitor Log Analytics (not App Insights), not subject to sampling. Captures prompt tokens, completion tokens, model, deployment per request. ~5 min ingestion delay but complete. **Limitation:** Cannot add custom dimensions (e.g., team name, priority tier, PTU vs PAYG) — schema is fixed. Only workaround is injecting custom headers and capturing them in gateway logs, which is fragile. This is why reference implementations build custom pipelines instead. **None of these references use built-in logs for chargeback.** |
| **Token granularity** | Prompt + completion (via metric dimensions) | Prompt, completion, total, audio tokens, cached tokens (from `usage.prompt_tokens_details`) | Prompt, completion, total (parsed from response `usage` JSON) | Prompt, completion, total (parsed from response body by Function) | Prompt + completion combined (internal counter, not exposed per-field) |
| **Identity tracking** | APIM Product ID (via `context.Product.Id` dimension) | appId (from subscription or custom header), productName, subscriptionId, endUserId, sessionId | JWT claims (`tid`, `aud`, `azp`/`appid`) — full Entra ID identity resolution | APIM subscription key (identity via `Ocp-Apim-Subscription-Key`) | Counter key — any policy expression (subscription ID, IP, custom claims) |
| **Rate limiting** | `azure-openai-token-limit` per Product subscription (TPM) | `llm-token-limit` with custom `counter-key` per team | Per-client quotas (monthly token limits) + TPM/RPM enforced via external API pre-check (`/api/precheck`) | None — tracking only, no enforcement | Native TPM rate limiting + monthly/daily/weekly quotas with sliding window |
| **Cost calculation** | Azure Monitor → KQL workbook. No per-model pricing table — relies on Azure Cost Management | EventHub → Logic App → Cosmos DB. Per-model pricing table (`model-pricing.json`) with separate input/output token rates. Formula: `(prompt × inputRate + completion × outputRate) / costUnit` | Redis + Cosmos DB. Per-model pricing rates managed via API (`/api/pricing`). Real-time cost computed on ingestion | Azure Function computes cost from token counts + pricing table in Redis. Results cached 30 days | No cost calculation — only token counting and enforcement |
| **Storage / reporting** | Azure Monitor metrics → Log Analytics Workbook (KQL). Deployed via `dashboard.bicep` | Cosmos DB (36-month retention) → Power BI dashboard. Usage records include full routing metadata | Redis (hot cache) + Cosmos DB (durable audit). React/TypeScript SPA with live WebSocket dashboard + CSV billing exports | Redis cache (30 day retention) → chargeback reports via API | None — in-memory counters only. Exposes remaining tokens via response headers/variables |
| **PTU support** | No PTU-specific tracking | Yes — tracks `backendId` and `routeName` to distinguish PTU vs PAYG. Cost formula supports `BaseCost` for PTU fixed pricing | No specific PTU handling | No specific PTU handling | No PTU awareness — same counter regardless of backend type |
| **Streaming support** | Yes — `azure-openai-emit-token-metric` handles streaming natively | Yes — separate `frag-openai-usage-streaming.xml` fragment using `azure-openai-emit-token-metric` | Yes — handles streaming responses | Solves APIM 8KB log truncation for large payloads (up to 100MB) | Yes — estimates prompt tokens during streaming (always, ignoring `estimate-prompt-tokens` setting) |
| **Tech stack** | APIM + Azure Monitor + KQL | APIM + EventHub + Logic App + Cosmos DB + Power BI | APIM + ASP.NET (.NET 10) + Redis + Cosmos DB + React/TS + .NET Aspire | APIM + Azure Functions (Python) + Redis | APIM built-in (no external dependencies) |
| **Complexity** | Low — uses only native APIM policies + Azure Monitor | High — full pipeline with 5 services and custom policy fragments | High — full .NET platform with dashboard, billing plans, DLP (Purview), and WebSocket streaming | Medium — Function app + Redis, IaC via Bicep/Terraform/ARM/Pulumi | Low — single policy element, no external dependencies |
| **Key limitation** | No per-model cost breakdown; limited to 6 custom dimensions on metrics; no identity beyond Product | EventHub adds latency; Logic App ingestion can lag; limited to 6 metric dimensions | External API call on every request adds latency (pre-check + log). Heavy infrastructure footprint | `send-request` to Function adds 50-200ms latency per request. 8KB workaround is the main value-add | Always returns 429 on exceeded — can't route to fallback. No cost data. No identity in logs |
