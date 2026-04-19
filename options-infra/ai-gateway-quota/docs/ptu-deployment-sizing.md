# PTU (Provisioned Throughput Units) Deployment Sizing Guide

> **Last updated:** July 2025
>
> This document covers PTU concepts, sizing guidance, and the PTU + PAYG spillover pattern used by our AI Gateway.

---

## 1. What Are PTUs?

**Provisioned Throughput Units (PTUs)** are Azure OpenAI's dedicated-capacity billing model. Each PTU represents a fixed slice of model inference capacity that provides:

- **Predictable, stable throughput and latency** — dedicated capacity not shared with other tenants
- **Lower throttling than PAYG** — but not zero; PTU provides an SLA, not a hard capacity guarantee
- **Simplified, predictable billing** — hourly or with reservation discounts (monthly/annual)

> ⚠️ **Quota ≠ Capacity.** PTU quota grants permission to *request* up to N PTUs, but does not reserve physical compute. Capacity is only confirmed when you successfully create a deployment. If a region is at capacity, deployment may fail even with available quota. Microsoft recommends: **deploy first, then purchase reservations.** See [PTU Onboarding](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/provisioned-throughput-onboarding).

### PTU vs Pay-As-You-Go (PAYG)

| Aspect | PTU (Provisioned) | PAYG (Standard) |
|---|---|---|
| **Billing** | Fixed hourly rate per PTU | Per-token (input + output) |
| **Capacity** | Dedicated (once deployed; quota ≠ guaranteed capacity) | Shared, best-effort |
| **Latency** | More consistent, lower on average | Variable under load |
| **Minimum commitment** | Yes (varies by deployment type) | None |
| **Cost efficiency** | Better at high, sustained utilization | Better for low/variable usage |
| **Throttling** | Less frequent, but still possible (SLA-based) | When exceeding TPM quota |

PTU quota is **model-independent** — the same PTU pool can be used across supported model families (GPT-4o, GPT-4.1, GPT-5, etc.) within a subscription and region.

---

## 2. PTU Capacity Calculator

Microsoft provides an official capacity calculator to estimate PTU requirements:

**Azure AI Foundry PTU Calculator:** <https://www.ptucalc.com/>

### How to use it

1. Select the **model** you plan to deploy (e.g., GPT-4o, GPT-4.1)
2. Enter your expected **requests per minute**
3. Enter average **input tokens per request** and **output tokens per request**
4. The calculator estimates the **number of PTUs** needed

> **Tip:** The calculator accounts for the output token weighting (output tokens cost more compute than input tokens). Always use representative workload profiles for accurate estimates.

---

## 3. PTU-to-TPM Mapping

Each PTU provides a different amount of tokens per minute (TPM) depending on the model. Output tokens are weighted more heavily than input tokens due to higher compute cost.

### Approximate PTU Capacity by Model

| Model | Input TPM per PTU | Output Token Ratio | Notes |
|---|---|---|---|
| GPT-4o | ~2,500 | 4:1 | Each output token ≈ 4 input tokens |
| GPT-4.1 | ~3,000 | 4:1 | Higher throughput per PTU |
| GPT-5-mini | ~23,750 | 8:1 | Small models offer significantly more TPM |
| GPT-5.4 | ~2,400 | 8:1 | Latest large model |

**Effective TPM calculation:**

```
Effective TPM = Requests/min × (Avg Input Tokens + (Avg Output Tokens × Output Ratio))
Required PTUs = Effective TPM ÷ Input TPM per PTU
```

> **Important:** These values change as Microsoft updates models and infrastructure. Always verify against the [official capacity calculator](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/provisioned-throughput-onboarding#latest-azure-openai-models) and documentation.

---

## 4. Minimum PTU Deployments

Minimum PTU requirements vary by deployment type:

| Deployment Type | Minimum PTUs | Increment | Best For |
|---|---|---|---|
| **Global Provisioned** | 15 PTUs | 5 PTUs | Multi-region, cost-optimized |
| **Data Zone Provisioned** | 15 PTUs | 5 PTUs | Data residency compliance |
| **Regional Provisioned** | 50 PTUs | 50 PTUs | Ultra-low latency, single region |

- **Global Provisioned** routes requests across Microsoft's global infrastructure for optimal utilization
- **Data Zone Provisioned** keeps data within a geographic zone (e.g., EU, US) for compliance
- **Regional Provisioned** pins capacity to a specific Azure region

---

## 5. Right-Sizing PTU Deployments

### The trade-offs

| Risk | Under-Provisioned | Over-Provisioned |
|---|---|---|
| **Cost** | Lower PTU cost, but PAYG spillover adds up | Higher PTU cost, wasted capacity |
| **Latency** | Frequent 429s, retries add latency | More consistent latency |
| **Reliability** | Depends on PAYG availability for overflow | Dedicated capacity, more predictable |

### Sizing approach

1. **Baseline from production traffic:** Analyze your actual requests/min, input/output token distributions
2. **Target 60–80% utilization:** Provision for your P80–P95 traffic, not the absolute peak
3. **Use PAYG for spikes:** Let the spillover pattern handle bursts above your provisioned capacity
4. **Monitor and adjust:** Review utilization weekly during initial deployment, monthly once stable
5. **Start conservative, scale up:** It's easier to add PTUs than to over-commit upfront

### Calculation example

```
Scenario: GPT-4o deployment
- 100 requests/min average
- 500 input tokens/request average
- 200 output tokens/request average
- Output ratio: 4:1

Effective TPM = 100 × (500 + (200 × 4)) = 100 × 1,300 = 130,000 TPM
Required PTUs = 130,000 ÷ 2,500 = 52 PTUs

→ Round up to nearest increment:
  - Global Provisioned: 55 PTUs (15 min + increments of 5)
  - Regional Provisioned: 100 PTUs (50 min + increments of 50)
```

---

## 6. PTU + PAYG Spillover Pattern

This is the architecture our AI Gateway implements. PTU serves as the primary capacity layer, with PAYG as an overflow safety net.

### Architecture

```
         ┌─────────────┐
         │   Clients    │
         └──────┬───────┘
                │
                ▼
    ┌───────────────────────┐
    │   AI Gateway (APIM)   │
    │   - Rate limiting     │
    │   - Auth / routing    │
    │   - Retry policies    │
    └───────┬───────┬───────┘
            │       │
      ┌─────┘       └─────┐
      ▼                    ▼
┌──────────────┐   ┌──────────────┐
│  PTU Backend │   │ PAYG Backend │
│  (Primary)   │   │ (Overflow)   │
│              │   │              │
│ Dedicated    │   │ On-demand    │
│ capacity     │   │ capacity     │
└──────────────┘   └──────────────┘
```

### How it works

1. **All requests route to the PTU deployment first** — lowest cost, more predictable latency
2. **If PTU returns HTTP 429 or 503** (rate limited / capacity exhaustion), the gateway retries against the PAYG backend
3. **PAYG absorbs the overflow** — higher per-token cost but no capacity reservation needed
4. **Gateway tracks routing metrics** — monitors what percentage of traffic spills over to PAYG

### APIM policy pattern (simplified)

```xml
<retry condition="@(context.Response.StatusCode == 429)"
       count="1" interval="0">
    <set-backend-service base-url="https://payg-openai.openai.azure.com/" />
    <forward-request />
</retry>
```

### Benefits

- **Cost-optimized:** PTU covers steady-state traffic at discounted rates
- **Burst-capable:** PAYG handles unpredictable spikes without over-provisioning PTUs
- **High availability:** If the PTU endpoint has issues, PAYG provides a fallback path
- **Right-sizing flexibility:** You can provision PTUs conservatively and let PAYG catch the rest

### Target spillover rate

- **< 5% spillover:** Well-provisioned — PTU handles nearly all traffic
- **5–20% spillover:** Consider adding PTUs if sustained; acceptable if spikes are infrequent
- **> 20% spillover:** Under-provisioned — add more PTUs to reduce PAYG costs

---

## 7. Cost Comparison: When PTU Makes Sense

### Rule of thumb

PTU becomes cost-effective when your sustained utilization exceeds roughly **60–70%** of provisioned capacity.

### Comparison scenarios

| Scenario | Recommended Model | Why |
|---|---|---|
| Steady, high-volume production workload | **PTU** | Predictable cost, dedicated performance |
| Variable or bursty traffic | **PTU + PAYG spillover** | Optimized cost with burst handling |
| Low-volume or experimental | **PAYG only** | No minimum commitment |
| Compliance / latency-sensitive | **Regional PTU** | Data residency + dedicated capacity |

### Reservation discounts

PTU costs can be further reduced with Azure reservations:

- **Monthly reservation:** Moderate discount over hourly billing
- **Annual reservation:** Up to ~60–70% savings vs hourly billing
- Reservations are **loosely coupled** to deployments — you can reassign PTU capacity across models without changing reservations

---

## 8. Monitoring PTU Utilization

### Key metrics to watch

| Metric | Description | Alert Threshold |
|---|---|---|
| **Provisioned-Managed Utilization V2** | % of PTU capacity in use | > 80% sustained |
| **HTTP 429 Responses** | Rate limit responses from PTU | Any increase |
| **Token Usage (Input/Output)** | Actual tokens processed per minute | Trending toward capacity |
| **Request Count** | Requests per minute to PTU deployment | Trending toward capacity |
| **PAYG Spillover Rate** | % of requests routed to PAYG backend | > 10% sustained |
| **End-to-End Latency** | P50/P95/P99 response times | Degradation from baseline |

### Azure Monitor setup

1. Navigate to your Azure OpenAI resource → **Monitoring → Metrics**
2. Select the `Provisioned-managed Utilization V2` metric
3. Split by **deployment name** to see per-deployment utilization
4. Create **alert rules** for:
   - Utilization > 80% for 15 minutes (warning — consider scaling)
   - Utilization > 95% for 5 minutes (critical — spillover likely occurring)
   - HTTP 429 count > 0 (investigate throttling)

### Diagnostic settings

For richer analysis, configure **Diagnostic Settings** to send metrics and logs to **Log Analytics**:

```
Azure OpenAI Resource → Diagnostic Settings → Add
  ✓ Metrics → Send to Log Analytics workspace
  ✓ Request and Response Logs → Send to Log Analytics workspace
```

This enables KQL queries for deeper utilization analysis and capacity planning.

---

## 9. References

| Resource | URL |
|---|---|
| Provisioned Throughput Overview | <https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/provisioned-throughput> |
| PTU Onboarding & Billing | <https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/provisioned-throughput-onboarding> |
| PTU Capacity Calculator | <https://oai.azure.com/capacity> |
| Right-Size Your PTU Deployment (Blog) | <https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/right-size-your-ptu-deployment-and-save-big/4060683> |
| Best Practice Guidance for PTU | <https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/best-practice-guidance-for-ptu/4152133> |
| Azure OpenAI Quotas and Limits | <https://learn.microsoft.com/en-us/azure/ai-services/openai/quotas-limits> |
| Monitor Azure OpenAI Usage | <https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/monitor-openai> |
| APIM Backend Pool / Retry Policies | <https://learn.microsoft.com/en-us/azure/api-management/backends> |
| Azure OpenAI Pricing | <https://azure.microsoft.com/en-us/pricing/details/cognitive-services/openai-service/> |
