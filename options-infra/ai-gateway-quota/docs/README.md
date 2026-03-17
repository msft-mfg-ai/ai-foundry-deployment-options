# Azure API Management routing to PTU deployments with BCDR scenarios

Designing a priority-based routing solution for Azure OpenAI PTU deployments using Azure API Management and Microsoft Foundry.

## Problem

When multiple internal teams share a PTU deployment with different priorities (production vs dev/test), we need to:
- Maximize PTU utilization (it's pre-paid)
- Ensure production traffic gets PTU preference
- Spill lower-priority traffic to PAYG first

## Documentation

- **[Architecture Plan](docs/architecture-plan.md)** — Full analysis of 5 options, 5 deployment topologies, comparison tables, Citadel & SimpleL7Proxy deep-dives, and phased implementation approach
- **[PTU Design Risks & Limitations](docs/ptu-design-risks.md)** — Deployment naming requirements, multi-region topology, token estimation, race conditions, and risk summary
- **[Requested APIM Features](docs/requested-apim-features.md)** — Feature gaps in APIM that would simplify PTU priority routing (atomic counters, auto-discovery, model routing, etc.)
- **[JWT Citadel Implementation](docs/jwt-citadel-implementation.md)** — Implementation details for the JWT-based priority routing policy

## ⚠️ Critical Requirement: Consistent Deployment Names

All Azure OpenAI / Foundry instances that serve the same model **must** use the **same deployment name**, and that name must equal the `modelName` in the configuration.

```
✅  PTU instance (eastus):    deployment "gpt-4.1-mini"
✅  Paygo instance (eastus):  deployment "gpt-4.1-mini"
✅  PTU instance (westus):    deployment "gpt-4.1-mini"

❌  PTU instance (eastus):    deployment "gpt-4.1-mini-ptu"   ← BREAKS routing (404)
```

APIM backend pools forward the URL path (`/openai/deployments/{name}/...`) unchanged to whichever backend is selected. Different names across backends in the same pool cause intermittent 404s. See [Section 5 of PTU Design Risks](docs/ptu-design-risks.md#5-deployment-naming-convention--hard-requirement) for the full rationale and setup checklist.

## Quick Summary

| Option | PTU Utilization | Complexity | Recommended? |
|--------|----------------|------------|-------------|
| Citadel (static limits) | 40-70% | Lowest | Phase 1 ✅ |
| Citadel + oversubscription | 70-85% | Lowest | Better starting point |
| Custom APIM policy | 85-95% | Medium | Phase 3 (if needed) |
| Event Hub queue | 95%+ (async only) | High | Batch/async workloads only |
| SimpleL7Proxy | 85-95% | Medium | Open Source project, true priority queue, with extra complexity ✅ |

**Recommended approach:** Start with Citadel access contracts + moderate oversubscription, monitor for 2-4 weeks, evolve to custom policy or SimpleL7Proxy if PTU underutilization persists.

## Deployment Topologies

| Topology | APIM SKU | HA/DR | Fully Private | Cost | Best For |
|----------|----------|-------|---------------|------|----------|
| **A: Single-Region** APIM + multi-region OpenAI backends | Standard v2 or Premium v2 | ❌ APIM is SPOF | ✅ Internal VNet (Premium v2) | 💰 Low | MVP, cost-sensitive |
| **B1: APIM Multi-Region** Internal VNet per region | **Premium classic** or **Premium v2** (multi-region requires Premium tier, v2 multi-region support is coming) | ✅ Auto failover | ✅ Fully private | 💰💰💰 | Production, private networks |
| **B2: Front Door + APIM** Private Link origin | **Standard v2** (or classic Standard/Premium). ⚠️ Premium v2 does NOT support Private Link origin for AFD | ✅ Global failover | ⚠️ Client→AFD public | 💰💰 | Public-facing APIs |
| **B3: App GW per Region** Custom DNS routing | Standard v2 or Premium tier (App GW routes to APIM private endpoint) | ✅ DNS failover | ✅ Fully private | 💰💰💰 | Zero public exposure |
| **B4: TM + App GW dual-IP** Split-horizon DNS |Standard v2 or Premium tier (App GW routes to APIM private endpoint) | ✅ TM auto failover | ✅ API traffic private | 💰💰💰 | Private + TM routing intelligence |

> **SKU notes:**
> - **B1** requires **APIM Premium** (classic or v2) — this is the only tier that supports multi-region gateway deployment. Budget ~$2.8K/mo base + ~$2.5K per additional region.
> - **B2** works with **APIM Standard v2** — Front Door handles multi-region routing, so APIM itself doesn't need to be multi-region. However, APIM **Premium v2 is NOT supported** as a Front Door Private Link origin (as of early 2026). Use classic APIM tiers or Standard v2, or add an Application Gateway between Front Door and APIM Premium v2.
> - **B3/B4** — Any APIM tier that supports private networking. App GW is the entry point and connects to APIM via private endpoint. APIM connects to OpenAI backends via their private endpoints (no VNet injection needed on either leg).

> ⚠️ **Traffic Manager cannot route to private endpoints directly.** B4 solves this with App GW dual frontend (public IP for TM health probes, private IP for API traffic) + split-horizon DNS. Requires careful DNS setup across public zones, Private DNS zones, on-prem forwarders, and Private Resolver.

## Research Sources

| Source | Link |
|--------|------|
| AI-Gateway | `Azure-Samples/AI-Gateway` |
| Foundry-with-APIM | Local repo |
| Citadel | [`Azure-Samples/ai-hub-gateway-solution-accelerator`](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) (citadel-v1 branch) |
| GenAI Playbook | [MS Learn: Maximize PTU Utilization](https://learn.microsoft.com/en-us/ai/playbook/solutions/genai-gateway/reference-architectures/maximise-ptu-utilization) |
| ai-gw-v2 | [`Heenanl/ai-gw-v2`](https://github.com/Heenanl/ai-gw-v2) (usecaseonboard / jwtauth branches) |
| SimpleL7Proxy | [`microsoft/SimpleL7Proxy`](https://github.com/microsoft/SimpleL7Proxy) |
