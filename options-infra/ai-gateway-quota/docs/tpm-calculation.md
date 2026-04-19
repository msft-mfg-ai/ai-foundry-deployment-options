# TPM (Tokens Per Minute) Calculation for Azure OpenAI

> Last updated: July 2025

## 1. What Is TPM?

**Tokens Per Minute (TPM)** is the primary quota and rate-limiting unit for Azure OpenAI. It defines the maximum number of tokens your subscription can process per minute for a given model deployment in a specific region.

A **token** is a chunk of text — roughly 4 characters or about ¾ of a word in English. Both input (prompt) and output (completion) tokens count toward your TPM quota.

TPM quotas are scoped **per-model, per-region, per-subscription**. You can split your regional quota across multiple deployments of the same model, but quotas are not shared across regions or subscriptions.

## 2. How Tokens Are Counted

When a request is submitted, Azure OpenAI **estimates** the total token consumption upfront for rate-limiting purposes:

```
Estimated Tokens = prompt_tokens + max_tokens × best_of
```

| Component | Description |
|---|---|
| `prompt_tokens` | Number of tokens in the input prompt |
| `max_tokens` | Maximum completion length you set in the request |
| `best_of` | Multiplier if using the `best_of` parameter (defaults to 1) |

### Key distinction: rate-limiting vs billing

- **Rate-limiting** uses the **estimated** token count (prompt + `max_tokens`) at request submission time.
- **Billing** uses the **actual** token count (prompt + generated completion tokens) after the response completes.

### Example

Three requests in one minute:

| Request | Prompt Tokens | max_tokens | Estimated Total |
|---------|--------------|------------|-----------------|
| 1 | 100 | 200 | 300 |
| 2 | 30 | 70 | 100 |
| 3 | 150 | 350 | 500 |
| **Total** | | | **900** |

If your TPM quota is 1,000, you are under the limit. Setting `max_tokens` to a reasonable value is critical — an unnecessarily high value consumes quota even if the model generates fewer tokens.

## 3. TPM vs RPM

Azure OpenAI enforces **two independent rate limits**:

| Limit | What It Measures | Typical Ratio |
|-------|-----------------|---------------|
| **TPM** (Tokens Per Minute) | Total tokens (prompt + completion) processed per minute | — |
| **RPM** (Requests Per Minute) | Number of API calls per minute | ~6 RPM per 1,000 TPM |

**Both limits are enforced simultaneously.** Exceeding either triggers a `429 Too Many Requests` response. The limits are monitored in short time slices (typically 1–10 seconds), so bursts within a minute can still trigger throttling.

### Example

With a quota of 240,000 TPM:
- Derived RPM ≈ 1,440 (240,000 ÷ 1,000 × 6)
- You must stay under **both** 240K TPM and 1,440 RPM

## 4. Model-Specific Quotas and Limits

Different models have different default and maximum TPM quotas. Azure does not use a single "multiplier" value; instead, each model family has its own quota allocation defined per tier and region.

### Representative quota limits (Enterprise tier, as of 2025)

| Model | Max TPM | Max RPM | Notes |
|-------|---------|---------|-------|
| gpt-4o (Global Standard) | Up to 30M | Up to 180K | Highest available quotas |
| gpt-4o-mini | Up to 50M | Up to 300K | Optimized for high-throughput |
| gpt-4 / gpt-4-turbo | Up to 5M | Up to 5K | Lower limits due to compute cost |
| gpt-4.1 / gpt-4.1-mini | Up to 5M | Up to 5K | Newer model family |
| gpt-35-turbo | Up to 240K+ | Varies | Legacy, widely available |

> **Note:** Actual limits depend on your subscription tier (Free, Tier 1–6, Enterprise/MCA-E), region availability, and any custom quota increases. Always check the [official quotas page](https://learn.microsoft.com/en-us/azure/ai-services/openai/quotas-limits) for current values.

### Quota tiers

Azure OpenAI uses a tiered quota system (Free, Tier 1–6, Enterprise) with automatic increases as your usage and payment history grow. Higher tiers unlock larger TPM allocations.

## 5. PTU vs TPM Billing

Azure OpenAI offers two deployment types with different billing and capacity models:

| Aspect | Pay-as-you-go (TPM) | Provisioned (PTU) |
|--------|---------------------|-------------------|
| **Capacity** | Shared infrastructure, variable | Dedicated compute (once deployed) |
| **Billing** | Per-token usage | Fixed hourly/monthly for reserved PTUs |
| **Rate limiting** | Subject to TPM/RPM quotas | No token-level throttling within PTU capacity |
| **Latency** | Variable (depends on load) | Consistent, lower latency |
| **Best for** | Dev/test, variable workloads | Production, predictable high-throughput |

### What is a PTU?

A **Provisioned Throughput Unit (PTU)** reserves a fixed amount of model processing capacity. Each PTU provides a defined throughput (tokens/second) that varies by model — more powerful models require more PTUs for equivalent throughput.

### When to choose PTU over TPM

- You need **predictable latency** and dedicated throughput
- Your workload is **predictable and sustained**
- You want to avoid `429` throttling entirely
- Cost is justified by the business-critical nature of the workload

## 6. Estimating TPM Needs

### Sizing formula

```
Required TPM = (Avg Input Tokens + Avg Output Tokens) × Requests Per Minute
```

### Step-by-step process

1. **Measure average token counts** — Use the [OpenAI Tokenizer](https://platform.openai.com/tokenizer) or the `tiktoken` library to count tokens in representative prompts and responses.

2. **Estimate request volume** — Determine your expected requests per second (QPS), then multiply by 60 for RPM.

3. **Calculate baseline TPM**
   ```
   Example:
   - Avg input:  500 tokens
   - Avg output: 300 tokens
   - QPS:        5 (= 300 RPM)

   TPM = (500 + 300) × 300 = 240,000 TPM
   ```

4. **Add a buffer for spikes** — Plan for 20–30% headroom above your average to handle traffic bursts.
   ```
   240,000 × 1.3 = 312,000 TPM (with 30% buffer)
   ```

5. **Account for `max_tokens` overhead** — Remember that rate-limiting uses `max_tokens`, not actual output. If your `max_tokens` is set higher than typical output, your effective TPM consumption will be higher than the formula above.

6. **Validate with monitoring** — After deployment, use Azure Monitor metrics to track actual token consumption, throttling events (`429` responses), and adjust quotas accordingly.

### Tips

- Set `max_tokens` as low as practical to avoid wasting quota
- Use streaming responses where possible to improve perceived latency
- Distribute load across multiple deployments or regions if hitting single-deployment limits
- Monitor the `Tokens Per Minute` and `Requests Per Minute` metrics in Azure Monitor

## 7. Managing Quotas

- View current quota usage in the Azure Portal under your OpenAI resource → **Usage + quotas**
- Request quota increases through the Azure Portal when defaults are insufficient
- Split quota across deployments: e.g., 240K TPM total can be split into two 120K TPM deployments
- Use [Azure API Management](https://learn.microsoft.com/en-us/azure/api-management/) as a gateway to implement custom rate-limiting, load balancing, and retry logic across multiple Azure OpenAI backends

## References

| Resource | URL |
|----------|-----|
| Azure OpenAI Quotas and Limits | https://learn.microsoft.com/en-us/azure/ai-services/openai/quotas-limits |
| Managing Azure OpenAI Quota | https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/quota |
| Provisioned Throughput (PTU) | https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/provisioned-throughput |
| Azure OpenAI Pricing | https://azure.microsoft.com/en-us/pricing/details/cognitive-services/openai-service/ |
| Performance and Latency Guide | https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/latency |
| OpenAI Tokenizer Tool | https://platform.openai.com/tokenizer |
| tiktoken (Python tokenizer library) | https://github.com/openai/tiktoken |
| Optimizing Azure OpenAI (Tech Community) | https://techcommunity.microsoft.com/blog/fasttrackforazureblog/optimizing-azure-openai-a-guide-to-limits-quotas-and-best-practices/4076268 |
