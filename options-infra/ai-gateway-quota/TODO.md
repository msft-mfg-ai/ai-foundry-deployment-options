# TODO — AI Gateway with Quota Tiers

## 1. Scaling to More Clients

**Status:** Not started
**Priority:** High

Currently supports ~20 client apps (`azp` entries). Expected to grow to 20–30, potentially up to 100.

- [ ] Document the [Named Value pair limit](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties) in APIM and its impact on scaling
- [ ] Evaluate alternatives for storing caller-tier mappings at scale (e.g., external cache, Cosmos DB lookup, policy expressions with backend call)
- [ ] Test and document the maximum number of entries in a single Named Value

## 2. Multi-Deployment Routing

**Status:** Not started
**Priority:** High

Route requests to different backend deployments based on the model requested. A model may be available in a different AI backend (e.g., PTU vs. PayGo, different regions).

### Requirements

- Route requests to the correct backend based on model name (from URL path or request body)
- Support load balancing and retries across backends
- Allow per-client routing rules (e.g., Gold-tier clients → PTU, Bronze-tier → PayGo)

### Reference Implementations

- **Simple routing with APIM policy** — [AI-Gateway lab: model-routing/policy.xml](https://github.com/Azure-Samples/AI-Gateway/blob/main/labs/model-routing/policy.xml)
- **Citadel AI Governance Hub** — Full 1:N gateway with backend onboarding, access contracts, and dynamic model discovery:
  - [Backend onboarding](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/llm-backend-onboarding)
  - [Access contracts](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1/bicep/infra/citadel-access-contracts)
  - [Validation notebook](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/blob/citadel-v1/validation/citadel-access-contracts-tests.ipynb)

## 3. Monthly Quota Notifications

**Status:** Not started
**Priority:** Medium

- [ ] Notify teams when their monthly token budget is approaching the limit (e.g., at 80% and 90% thresholds)
- [ ] Evaluate notification channels: email, Teams webhook, or Azure Monitor action groups
- [ ] Add threshold-based KQL alerts in addition to the existing over-budget alert