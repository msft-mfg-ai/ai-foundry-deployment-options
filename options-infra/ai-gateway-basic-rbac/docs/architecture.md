# Architecture

## Overview

```
┌──────────────────────────── Resource group (validation) ─────────────────────────────┐
│                                                                                       │
│  Foundry account (disableLocalAuth=true)                                              │
│    └── AI Project #1  ── managed identity                                             │
│                                                                                       │
│  APIM Basic v2 (from ai-gateway-basic)                                                │
│    └── per-model backends → external Foundry / AOAI instance(s)                       │
│                                                                                       │
│  Log Analytics + App Insights + Dashboard                                             │
│                                                                                       │
│  Bicep-created role assignments:                                                      │
│    sp-foundry-<env>-builder        → Foundry User (project)                           │
│    sp-foundry-<env>-runtime        → Foundry Agent Consumer (project)                 │
│    sp-foundry-<env>-platform       → Foundry Account Owner (account)                  │
│    sp-foundry-<env>-project-admin  → Foundry Project Manager (project)                │
│    sp-foundry-<env>-none           → (baseline, no assignment)                        │
│                                                                                       │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

## Test flow

1. **Preprovision** — `preprovision-list-foundry-models.sh` discovers external Foundry deployments, then `preprovision-rbac-sps.sh` creates the 5 SPs (idempotent by display name) and appends fresh client secrets. Both write to azd env.
2. **Bicep deploy** — provisions Foundry + project + APIM + assigns the persona roles.
3. **Postprovision** — `postprovision-write-tests-env.sh` writes `tests/.env` with tenant, subscription, endpoints, SP object IDs, and client secrets.
4. **Pytest** — the suite authenticates as each SP via `ClientSecretCredential`, runs the RD/AS/B/N/R/CTRL test IDs, and writes evidence to `tests/output/rbac-validation-results.{json,csv}`.

## Design notes

- **Why one option instead of extending `ai-gateway-basic`**: keeps the harness self-contained. Base option leaves local auth enabled (needed for its APIM integration), while this option needs it disabled for N-08 to pass by design.
- **Why 5 SPs**: matches the personas defined in `foundry-rbac-ghcp-implementation-spec.html`. Even the "none" persona is a real SP so `test_assignments.py` can verify a zero-role baseline.
- **Role assignment reuse**: `role-assignment-foundryProject.bicep` (project scope) and `role-assignment-cognitiveServices.bicep` (account scope) — both extended in this PR to accept the new `Foundry *` role names as aliases for the underlying GUIDs (some of which are also known by their `Azure AI *` legacy names).
- **Client secrets**: appended per `azd up` and written to `tests/.env` only. Nothing is committed. Old secrets are left in place until manually pruned.
