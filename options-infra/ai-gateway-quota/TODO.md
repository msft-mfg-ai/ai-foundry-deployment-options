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