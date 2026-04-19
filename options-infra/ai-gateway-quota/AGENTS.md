# AGENTS.md — AI Coding Agent Guide

## Project Overview

This project implements an **APIM AI Gateway** inspired by the [Citadel access contracts pattern](https://github.com/Azure-Samples/ai-hub-gateway-solution-accelerator/tree/citadel-v1) for managing Azure OpenAI traffic. It provides:

- **2-tier priority routing**: Production (priority 1) and Standard (priority 2) traffic classes
- **PTU + PAYG spillover**: Requests first attempt PTU (Provisioned Throughput Units) backends, then spill over to PAYG (Pay-As-You-Go) on capacity exhaustion

## Directory Structure

```
ai-gateway-quota/
├── modules/apim/advanced/   # Shared policy XML files (used by both Bicep and Terraform)
├── tf/                      # Terraform deployment
├── tests/                   # Test notebook
└── docs/                    # Documentation
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
- Response header injection (quota remaining, backend used, etc.)

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
