# TODO — AI Gateway with Quota Tiers

## 1. Scaling to More Clients

**Status:** ✅ Implemented (access contracts in blob storage)
**Priority:** High

Currently supports ~20 client apps (`azp` entries). Expected to grow to 20–30, potentially up to 100.

Access contracts are now stored as JSON in Azure Blob Storage (cached 5 min in APIM), removing the Named Value pair limit. Identity matching supports multiple claim types (`azp`, `appid`, `xms_mirid`, `oid`, `sub`) with prefix matching.

- [x] Document the [Named Value pair limit](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties) in APIM and its impact on scaling
- [x] Evaluate alternatives for storing caller-tier mappings at scale (e.g., external cache, Cosmos DB lookup, policy expressions with backend call)
- [x] Test and document the maximum number of entries in a single Named Value
- [ ] Load test with 100+ contracts in blob storage

## 2. Multi-Deployment Routing

**Status:** ✅ Implemented (per-model PTU + PAYG pools with priority routing)
**Priority:** High

Route requests to different backend deployments based on the model requested. A model may be available in a different AI backend (e.g., PTU vs. PayGo, different regions).

Implemented via per-model backend pools (`{model}-ptu-pool`, `{model}-payg-pool`). Each pool aggregates all Foundry instances that serve that model. Priority routing directs P1 → PTU first (with PAYG failover on 429), P2 → PTU when idle, P3 → always PAYG. Circuit breaker handles backend failures.

### Requirements

- [x] Route requests to the correct backend based on model name (from URL path or request body)
- [x] Support load balancing and retries across backends
- [x] Allow per-client routing rules (e.g., Gold-tier clients → PTU, Bronze-tier → PayGo)

### Reference Implementations

- **Simple routing with APIM policy** — [AI-Gateway lab: model-routing/policy.xml](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/model-routing/policy.xml)
- **Citadel AI Governance Hub** — Full 1:N gateway with backend onboarding, access contracts, and dynamic model discovery:
  - [Backend onboarding](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/llm-backend-onboarding)
  - [Access contracts](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/citadel-access-contracts)
  - [Validation notebook](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/citadel-v1/validation/citadel-access-contracts-tests.ipynb)

## 3. Monthly Quota Notifications

**Status:** Event Hub Notification Done. Email Not started
**Priority:** Medium

- [ ] Notify teams when their monthly token budget is approaching the limit (e.g., at 80% and 90% thresholds)
- [ ] Evaluate notification channels: email, Teams webhook, or Azure Monitor action groups
- [ ] Add threshold-based KQL alerts in addition to the existing over-budget alert

## 5. Per consumer configuration

**Status:** ✅ Implemented (access contracts with per-team models, quotas, and priority)
**Priority:** High

Access contracts define per-team configuration: allowed models, per-model TPM limits, PTU allocations, monthly token budgets, and routing priority. Contracts are defined in `main.bicepparam` and compiled to blob storage at deploy time. Teams can have auto-created Entra ID apps or bring pre-existing identities.

- [x] Allow APIM Operations team to specify models, quotas (TMP/Monthly), email for notifications, traffic priority (PTU / PAYGO)
- [ ] Self-service UI for APIM ops team to manage contracts without redeploying

## 6. Virtual Quotas for PTU

**Status:** ✅ Implemented (per-model `ptuTpm` with PAYG overflow)
**Priority:** High

Each team's access contract specifies `ptuTpm` per model — a soft PTU allocation enforced via `llm-token-limit` in the PTU gate loopback API. When the PTU allocation is exceeded, requests overflow to the PAYG pool automatically. P1 callers get PTU priority; P2 callers get PTU when utilization is low; P3 callers always route to PAYG.

- [x] Teams should be able to specify virtual Quota (TPM) for PTU deployment per team, when exceeded request should be routed to PAYGO deployment

### References

- [Token Limit Policy](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
- [APIM ChargeBack](https://github.com/seiggy/apim-chargeback)

## 7. Chargeback - FinOps

Have reports that show how many tokens were used from a given deployment and their cost.
For PTU, specify % of PTU quota used.

- [ ] Dashboard to show Cost per team
- [ ] PTU deployment should take note of free requests (cache used) an specify how much PTU deployment was consumed

### Reference Implementation

- [APIM OpenAI Chargeback](https://github.com/andyogah/apim-openai-chargeback-environment)
- [AI Gateway FinOps](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/finops-framework/finops-framework.ipynb)
- [Power BI Report](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/citadel-v1/guides/power-bi-dashboard.md)
- [APIM ChargeBack](https://github.com/seiggy/apim-chargeback)

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

### APIM Data Pipeline Limitations for Chargeback

Customers attempting to build chargeback on APIM face a fundamental conflict between APIM's two logging mechanisms — neither is sufficient on its own:

#### `llm-emit-token-metric` / `azure-openai-emit-token-metric` → App Insights

- **Destination:** Application Insights custom metrics (NOT Azure Monitor Log Analytics)
- **Reliability:** ⚠️ Subject to [App Insights sampling, throttling, and a 50K active time series limit](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-limits). High-cardinality dimensions (per-user, per-team) can exhaust the limit quickly. Metrics may be **silently dropped** under load — no error, no warning, just missing data.
- **Dimension limits:** Max 10 dimension keys per metric (APIM uses 5 internally, leaving 5 for custom). Max 50K unique time series per subscription/region/12h.
- **Customizable:** ✅ Up to 5 custom dimensions (e.g., Product ID, subscription, app ID)
- **Latency:** Near real-time
- **Verdict:** Good for dashboards and near-real-time monitoring. **Not suitable as system of record for billing/chargeback** due to potential data loss under load.

#### `ApiManagementGatewayLlmLog` (built-in LLM logs) → Azure Monitor Log Analytics

- **Destination:** Azure Monitor Log Analytics (workspace-based)
- **Reliability:** ✅ Not subject to App Insights sampling. Complete record of every request.
- **Customizable:** ❌ **Fixed schema** — no `callerId`, `teamName`, `subscriptionName`, `priorityTier`, or `backendType` (PTU vs PAYG). Cannot add custom dimensions. Only workaround is injecting custom headers in policy and hoping they appear in `ApiManagementGatewayLogs` (not `LlmLog`), then joining the two tables via `OperationId` in KQL — fragile and complex.
- **Latency:** ~5 minute ingestion delay
- **Token granularity:** Prompt tokens, completion tokens, total tokens, model, deployment name
- **Verdict:** Most reliable token data source. **Unusable for chargeback without identity dimensions.** Adding custom dimensions to `LlmLog` schema (or allowing user-defined fields) would make this the obvious solution.

#### The Gap

The reliable source (`LlmLog`) lacks identity. The customizable source (`emit-token-metric`) can lose data. **This is why every reference implementation above builds a custom pipeline** — using EventHub, external APIs, or Azure Functions to get both reliability and identity in one place. A native solution would eliminate all of this complexity.

**What would fix this:** Add custom dimension support to `ApiManagementGatewayLlmLog` — even just `callerId`, `productName`, and `backendType` would make built-in logs sufficient for chargeback without any custom pipeline.