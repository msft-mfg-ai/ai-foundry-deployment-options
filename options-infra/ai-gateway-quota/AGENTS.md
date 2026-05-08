# AGENTS.md — AI Coding Agent Guide

## Project Overview

This project implements an **APIM AI Gateway** inspired by the [Citadel access contracts pattern](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) for managing Azure OpenAI traffic. It provides:

- **Access contract enforcement**: Each caller is issued a contract defining their TPM rate limit, monthly token quota, priority tier, and allowed models. Contracts are enforced via APIM policies validated against incoming JWTs.
- **2-tier priority routing**: Production (priority 1) and Standard (priority 2) traffic classes
- **PTU + PAYG spillover**: Requests first attempt PTU (Provisioned Throughput Units) backends, then spill over to PAYG (Pay-As-You-Go) on capacity exhaustion
- **Portal dashboard**: An Azure Portal dashboard (`dashboard/dashboard.bicep`) visualizes per-caller token usage, quota consumption, rate limit events, spillover counts, and remaining quota. All data flows from outbound response headers → `ApiManagementGatewayLogs.ResponseHeaders` via APIM diagnostics.

## Directory Structure

```
ai-gateway-quota/
├── dashboard/               # Azure Portal dashboard (Bicep)
│   └── dashboard.bicep      # KQL-based dashboard tiles for quota/spillover monitoring
├── tf/                      # Terraform deployment
│   └── policies/            # Terraform-specific copies of the shared policy XML files
├── tests/                   # Test notebook
└── docs/                    # Documentation

# Shared policy XML files live in the modules directory, not under ai-gateway-quota:
options-infra/modules/apim/advanced/
├── policy-priority.xml      # Main routing + quota enforcement policy
├── fragment-identity.xml    # JWT validation and contract lookup
├── policy-config-viewer.xml # HTML contract config debug endpoint
├── token-estimation-*.xml   # Token estimation helpers (inbound/outbound)
└── types.bicep              # Bicep type definitions for contracts
```

## Policy Files

### `fragment-identity.xml`
JWT validation, contract lookup, and claim extraction. Validates incoming JWTs against the configured tenant, extracts the contract ID, and loads the associated contract configuration (TPM limits, priority tier, etc.).

### `policy-priority.xml`
Main routing policy orchestrating the full request lifecycle:
- TPM quota enforcement
- Priority-based backend selection
- PTU gate invocation (via loopback)
- Retry logic for PTU → PAYG spillover
- Response header injection (quota remaining, backend used, spillover flag, etc.)

Key outbound response headers set by this policy (all logged to `ApiManagementGatewayLogs.ResponseHeaders`):

| Header | Description |
|---|---|
| `x-quota-remaining-tokens` | Monthly token budget remaining for the caller |
| `x-quota-limit-tokens` | Caller's monthly token quota |
| `x-ratelimit-remaining-tokens` | Per-model TPM budget remaining |
| `x-backend-type` | Actual backend used: `ptu` or `payg` (resolved after circuit-breaker failover) |
| `x-spillover` | `"true"` if request was routed to PTU but landed on PAYG (capacity exhaustion); `"false"` otherwise |
| `x-route-target` | Inbound routing intent: `ptu` or `payg` |
| `x-caller-name` | Contract/caller name |
| `x-caller-priority` | Priority label (`production` or `standard`) |

### `policy-ptu-gate.xml`
Internal PTU gate policy for atomic token counting via a loopback API call. This enables checking PTU capacity and decrementing token counters in a single atomic operation, preventing race conditions.

### `policy-config-viewer.xml`
HTML dashboard endpoint that renders the current contract configuration. Useful for debugging and verifying that contracts are loaded correctly.

## Placeholder System

The shared XML policy files use placeholders that get substituted differently depending on the deployment method (Bicep vs Terraform):

| Placeholder | Description | Bicep | Terraform |
|---|---|---|---|
| `{contracts-load-section}` | How contract config is loaded | Blob storage | APIM named value (no storage account) |
| `{tenant-id}` | Azure AD tenant ID for JWT validation | Substituted at deploy | Substituted at deploy |
| `{eventhub-logger-id}` | Event Hub logger resource ID | Event Hub logger ID | Empty (not yet implemented) |
| `{internal-api-key}` | Internal key protecting the loopback API | Generated at deploy | Generated at deploy |
| `{loopback-backend-id}` | Loopback backend resource ID for PTU gate calls | Backend resource ID | Backend resource ID |
| `{contracts-source-label}` | Label shown in config viewer for contract source | `"blob"` | `"named-value"` |
| `{ptu-backend-hosts}` | Comma-separated PTU backend hostnames for spillover detection | PTU host list | PTU host list |

## Dashboard

`dashboard/dashboard.bicep` deploys an Azure Portal dashboard backed by Log Analytics KQL queries. All data comes from `ApiManagementGatewayLlmLog` (token counts) joined with `ApiManagementGatewayLogs` (caller identity and routing headers).

Key panels:
- **Caller Quota Overview** — monthly token usage per caller
- **Token Usage Over Time** — hourly stacked bar chart by caller
- **Rate Limit Events** — 429 throttle events by caller
- **💰 Remaining Monthly Quota** — latest `x-quota-remaining-tokens` per caller with % used
- **🔀 PTU→PAYG Spillover Summary** — per-caller spillover count and rate
- **📉 Spillover Over Time** — hourly spillover chart by caller
- **Model Usage by Caller** — per-deployment token breakdown
- **Monthly Budget Burn-Down** — cumulative token usage this month

The logging pipeline for observability headers: APIM policy sets response headers → `responseLogSettings` in `inference-api.bicep` captures them → they appear in `ApiManagementGatewayLogs.ResponseHeaders` as a JSON string.

## Key Gotchas

### `set-variable` NOT Allowed in `<backend>` Section
APIM does not allow `<set-variable>` inside the `<backend>` section. Any variable assignments must happen in `<inbound>` or `<outbound>`.

### PTU Returns 503 for Capacity Exhaustion
PTU backends return **503** (not just 429) when capacity is exhausted. Retry logic must handle both 429 and 503 status codes.

### `llm-token-limit` is Inbound-Only
The `llm-token-limit` policy can only be used in the `<inbound>` section. It cannot be applied in `<backend>` or `<outbound>`.

### `estimate-prompt-tokens` Must Be Consistent
The `estimate-prompt-tokens` setting must match between the PTU gate and the main API policy. Mismatches will cause token accounting drift.

### Quota Header Bouncing on APIM StandardV2
The `x-quota-remaining-tokens` header may bounce (fluctuate) on APIM StandardV2. This is platform behavior — the value is an estimate, not an exact count.

### `OpenAITokenQuotaExceeded` Has Capital Q
The error code is `OpenAITokenQuotaExceeded` (capital **Q** in Quota). Case-sensitive matching will fail if you use a lowercase q.

### Circuit Breaker Causes `PoolIsInactive`
When a circuit breaker trips on a backend pool, the error surfaced is `PoolIsInactive`. Handle this in retry/error logic accordingly.

### Policy Files Exist in Two Locations
The canonical policy XML files are in `options-infra/modules/apim/advanced/`. The Terraform deployment has its own copies in `ai-gateway-quota/tf/policies/`. Keep them in sync when making changes.
