# JWT-Based Citadel Access Contracts — Design History

> **Note (July 2025):** The loopback/PTU Gate pattern described here has been replaced with APIM's native circuit breaker + priority-based mixed pools. See the main [README](../README.md) for current architecture.
> This document is kept for historical context — it summarizes the original design plan and how the production system diverged.
> For the current architecture, see the main [README](../README.md) and [AGENTS.md](../AGENTS.md).

## What Was Planned vs What Was Built

| Planned | Built |
|---------|-------|
| Three priority tiers (P1/P2/P3) with P2 = "PTU when idle" | P2 abandoned — only P1 (PTU first) and P3 (PAYG only). P2 routes same as P3. |
| Custom token estimation (`token-estimation-*.xml`) for pre-debit/reconcile | `llm-token-limit` handles estimation internally — custom fragments retained as reference only |
| Cache-based PTU utilization tracking (`ptu-remaining`, `ptu-consumed`) | Two-API loopback — PTU Gate enforces capacity atomically via `llm-token-limit` |
| Single API with all logic in one policy | Two-API architecture: Priority API (external) + PTU Gate API (internal loopback) |
| Monthly quota for all callers | Monthly quota is PAYG-only — PTU is pre-paid, P1 callers exempt |
| 500+ lines of policy | ~250 lines total across Priority API + PTU Gate + shared fragment |

## What We Adapted from Citadel

| Citadel Feature | Keep? | Adaptation |
|---|---|---|
| Access Contract JSON schema | ✅ | Replace `infrastructure.apim.subscriptionId` with multi-identity `identities` array |
| Per-team model access control | ✅ | JWT claim → allowed models lookup (blob storage, not Product) |
| Per-team TPM + quota limits | ✅ | `counter-key` = JWT claim instead of `context.Subscription.Id`; per-model TPM via `models` map |
| Backend pool routing (priority/weight) | ✅ | No change — same Bicep modules |
| Circuit breaker on 429 | ✅ | No change |
| APIM Products per contract | ❌ | Replaced by JWT claim → config lookup |
| APIM Subscription keys | ❌ | Not used — fully keyless |
| Key Vault for subscription keys | ❌ | Not needed (no keys to store) |

## Key Design Decisions

- **P2 (PTU when idle) abandoned** — utilization tracking via cache or response headers added too much complexity for the benefit. See [PTU Design Risks §4](ptu-design-risks.md#4-p2-priority--feasibility-assessment).
- **`llm-token-limit` replaced all custom counters** — cache-based PTU tracking was strictly worse for atomicity, and APIM cache uses fixed-interval expiry (not sliding windows), making it fundamentally unsuitable for matching PTU's 60-second window.
- **Two-API loopback architecture** — Priority API handles identity/authorization/routing; PTU Gate API enforces PTU capacity. The loopback call is caught by `<retry>` — if PTU returns 429, the Priority API falls back to PAYG.
- **Monthly quota is PAYG-only** — PTU is pre-paid, so P1 monthly quota enforcement would penalize teams for using capacity they already paid for.
- **Policy fragments extracted** — Identity/contract resolution in `fragment-identity.xml` (~80 lines) shared across both APIs via `<include-fragment>`.
- **Pools fully separated** — PTU-only (`{model}-ptu-pool`) and PAYG-only (`{model}-payg-pool`), no mixed pools. The routing policy selects the correct pool.

## Implementation Files

| File | Purpose |
|------|---------|
| `modules/apim/advanced/policy-priority.xml` | Priority API policy — JWT validation, contract lookup, TPM/quota enforcement, routing |
| `modules/apim/advanced/policy-ptu-gate.xml` | PTU Gate API policy — PTU capacity enforcement via `llm-token-limit` |
| `modules/apim/advanced/fragment-identity.xml` | Shared identity/contract resolution fragment |
| `modules/apim/advanced/multi-foundry-backends.bicep` | Per-model backend pools (PTU + PAYG) |
| `modules/apim/advanced/contract-storage.bicep` | Blob storage for access contract JSON |
| `modules/apim/advanced/types.bicep` | Canonical type definitions |
