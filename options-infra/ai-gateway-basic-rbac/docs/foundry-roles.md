# Foundry Built-in Roles &mdash; Reference for this Deployment

This document explains each of the six built-in **Foundry** RBAC roles used in `options-infra/ai-gateway-basic-rbac`: what the role is for, who to assign it to, and which tests in this harness prove it behaves correctly.

Authoritative source: [Role-based access control for Microsoft Foundry &mdash; Microsoft Learn](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry).

> **Naming note (from Microsoft Learn):** Foundry RBAC roles were recently renamed. **Foundry User**, **Foundry Owner**, **Foundry Account Owner**, and **Foundry Project Manager** were previously **Azure AI User / Owner / Account Owner / Project Manager**. Role IDs and permissions are unchanged &mdash; ARM still accepts both names, and this repo's IAM modules alias them to the same GUIDs.
>
> **Do NOT use** roles starting with `Cognitive Services *` or the legacy `Azure AI Developer` role &mdash; those are for AI Services / AML hubs, not Foundry projects. Use the roles below.

---

## Role summary

| Role | GUID | Typical scope | One-line description (per Microsoft Learn) |
|---|---|---|---|
| [Foundry Agent Consumer](#foundry-agent-consumer)         | `eed3b665-ab3a-47b6-8f48-c9382fb1dad6` | Project or Agent | "Grants access to interact with agent endpoints in a Foundry project. Least-privilege role for principals that only need to interact with agents." |
| [Foundry Project Runtime User](#foundry-project-runtime-user) | `142bfaed-a13f-4c2d-bed2-6db62c4a1009` | Project | Allows interacting with Foundry agents at runtime via the OpenAI Responses API with minimal permissions. |
| [Foundry User](#foundry-user)                             | `53ca6127-db72-4b80-b1b0-d745d6d5456d` | Project or Account | "Reader access to Foundry project and resource plus data actions for the project. Least-privilege role for **developers building and testing agents**." |
| [Foundry Project Manager](#foundry-project-manager)       | `eadc314b-1a2d-4efa-be10-5d325db5065e` | Project | "Perform management actions on Foundry projects, build and develop with projects, and **conditionally assign the Foundry User role** to other user principals." |
| [Foundry Account Owner](#foundry-account-owner)           | `e47c6f54-e4a2-4754-9501-8e0985b135e1` | Account | "Full access to manage projects and resources, and conditionally assign Foundry User, ACR, and monitoring roles." |
| [Foundry Owner](#foundry-owner)                           | `c883944f-8b7b-4483-af10-35834be79c4a` | Account | "Full access to manage projects and resources AND build/develop with projects. Highly privileged self-serve role for digital natives." |

Test evidence for each role's GUID/permissions is asserted in `tests/test_role_definitions.py` (RD-01) and `tests/output/foundry-role-definitions.actual.json`.

---

## Foundry Agent Consumer

- **GUID:** `eed3b665-ab3a-47b6-8f48-c9382fb1dad6`
- **Data actions:** `Microsoft.CognitiveServices/accounts/AIServices/endpoints/interact/action`
- **Management actions:** none
- **Recommended scope:** Project (or narrower &mdash; individual agent scope is supported).

### Purpose

Least-privilege role for principals that need to **call an already-deployed agent's public endpoint** and nothing else. It grants a single action &mdash; `endpoints/interact/action` &mdash; used by the classic per-agent interact / chat surface. It does **not** grant the Responses API (`AIServices/responses/*`), agent management, project reads, or key access.

Microsoft's guidance on the [rbac-foundry page](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry): *"If a user or service principal only needs to interact with agents (for example, calling the Responses API) without creating or modifying them, assign **Foundry Agent Consumer** instead of Foundry User."*

### Assign it to

| Assignee | When |
|---|---|
| Managed identity of a **front-end app / chat UI** | The app relays end-user prompts to a specific agent and streams the reply back. |
| **End-user principals** (via Entra group) | You want authenticated tenant users to appear in Foundry audit logs and be able to chat with a specific agent. |
| Bots, IVR systems, back-office automation | Anything that only needs to *talk to* an agent. |

### Do NOT assign it to

- Developers who need to build agents &rarr; use `Foundry User`.
- Apps that need to call `POST /openai/v1/responses` &rarr; see the [gap under Foundry Project Runtime User](#-current-gap-r-03).

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry Agent Consumer** | `test_role_definitions.py` | Role definition GUID + `dataActions` are exactly `[endpoints/interact/action]` and `actions` is empty. |
| **AS-01/runtime**                | `test_assignments.py`      | Persona SP `sp-...-runtime` has ONLY this role at project scope, with no inherited broader RBAC. |
| **R-01**                         | `test_runtime.py`          | Denied `GET /agents?api-version=v1` &mdash; proves no `agents/read`. |
| **R-02**                         | `test_runtime.py`          | Denied `POST /agents/{name}/versions?api-version=v1` &mdash; proves no `agents/write`. |

---

## Foundry Project Runtime User

- **GUID:** `142bfaed-a13f-4c2d-bed2-6db62c4a1009`
- **Data actions:** `Microsoft.CognitiveServices/accounts/AIServices/responses/*`
- **Management actions:** none
- **Recommended scope:** Project.

### Purpose

Least-privilege role for principals that need to **invoke a v2 agent via the OpenAI Responses API** (`POST /openai/v1/responses`, streaming, conversations, message events). Grants exactly one dataAction &mdash; `AIServices/responses/*` &mdash; and nothing else: no agent listing, no project reads, no key access, no control-plane operations.

Think of it as the counterpart to Foundry Agent Consumer for the newer Responses-API surface (agents v2), where "Agent Consumer" is scoped to the older per-agent `interact` endpoint.

### Assign it to

| Assignee | When |
|---|---|
| **Managed identity of a web/API app** (App Service, Container Apps, AKS) | Server-side code calls `/openai/v1/responses` after authenticating its own end users. Most common case. |
| **Bot / function / batch job MI** | Any workload that only needs to *use* an agent someone else already built. |
| **FIC on a workload / GitHub Actions** | CI smoke tests or scheduled agent invocations. |
| **Service principal for evaluations / canaries** | Load tests, SLA monitors. |
| Individual end users | Rarely; usually route through the app's MI. |

### Do NOT assign it to

- Agent builders / developers &rarr; use `Foundry User`.
- Project admins &rarr; use `Foundry Project Manager`.
- Platform / IT operators &rarr; use `Foundry Account Owner`.

### ⚠️ Current gap (R-03)

Test **R-03a** proves an important limitation as of July 2026:

> A principal with **only** `Foundry Project Runtime User` **cannot** currently invoke `POST /api/projects/{project}/openai/v1/responses` against a v2 agent. Foundry's authorization for that endpoint checks `Microsoft.CognitiveServices/accounts/AIServices/agents/write`, which the role does **not** grant. The call fails with HTTP 403 &mdash; *"The principal ... does not have permissions for AIServices/agents/write on ..."*.

**Practical implication:** to give a runtime app the ability to invoke v2 agents via Responses API today, assign **`Foundry User`** (validated in R-03b) or combine this role with something that grants `agents/write`. Once Microsoft removes the `agents/write` check on `/responses`, you can demote back to this least-privilege role &mdash; re-run `test_r03_responses_api_via_project_runtime` to confirm.

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry Project Runtime User** | `test_role_definitions.py` | GUID + `dataActions` are exactly `[responses/*]`, `actions` is empty. |
| **AS-01/responses**                    | `test_assignments.py`      | Persona SP has ONLY this role at project scope. |
| **R-03a**                              | `test_runtime.py`          | Documents the 403 gap on `/openai/v1/responses`. |
| **R-03b**                              | `test_runtime.py`          | Foundry User CAN invoke &mdash; establishes the interim persona. |

---

## Foundry User

- **GUID:** `53ca6127-db72-4b80-b1b0-d745d6d5456d` (alias of *Azure AI User*)
- **Scope:** Project (usually) or Account.
- **What it grants:** Reader over the Foundry project + Foundry resource, plus **all data-plane actions inside the project** &mdash; create/edit agents, tools, threads, evaluations, files, connections. Does **NOT** grant control-plane management (creating projects/accounts, RBAC, model deployments).

### Purpose

Microsoft calls this the **"least-privilege role for developers building and testing agents."** It maps 1-to-1 to the customer's "builder" persona: build agents, create tools/skills, create knowledge sources, configure guardrails, run evaluations, build workflows.

### Assign it to

| Assignee | When |
|---|---|
| **Developers / data scientists** building agents in a specific project. | Day-to-day builder workflow. |
| The **project's managed identity** (assigned to the MI on the Foundry resource). | Microsoft explicitly requires this so the project can act on its own connections. See "Minimum role assignments to get started" on the [rbac-foundry Learn page](https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry). |
| **Runtime applications** that call `/openai/v1/responses` &mdash; interim workaround until the [R-03 gap](#-current-gap-r-03) is fixed. |

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry User** | `test_role_definitions.py` | Role definition GUID + role name. |
| **AS-01/builder**      | `test_assignments.py`      | Persona SP has ONLY this role at project scope. |
| **B-01, B-02, B-06**   | `test_builder_positive.py` | Can list & create v2 agents, run evaluations. |
| **B-03, B-04, B-05, B-07** | `test_builder_positive.py` | Documented as UI-only in `docs/manual-ui-test-plan.md` (tools, knowledge, guardrails, workflows). |
| **N-01 &hellip; N-08** | `test_builder_negative.py` | Confirms this role does NOT grant: create Foundry account/project, deploy models, create Logic Apps or storage, assign roles, publish to Teams, list account keys. |
| **R-03b**              | `test_runtime.py`          | Can invoke Responses API (interim runtime persona). |

### ⚠️ Known gap &mdash; guardrails

Portal validation as Joe (Foundry User at project scope) shows the **Guardrails / Content Safety configuration surface is hidden or read-only** &mdash; creating a new guardrail requires **Foundry Project Manager** or higher. This **breaks the customer requirement that builders configure their own guardrails.** Options:

1. Elevate the builder persona to `Foundry Project Manager` (trade-off: they also gain conditional roleAssignments/write for Foundry User inside the project).
2. Keep `Foundry User` and treat guardrail configuration as an admin-only activity documented in the ops runbook.
3. Escalate to Microsoft to expose guardrail configuration to `Foundry User` &mdash; this is a role-definition gap, not a Bicep/policy issue.

---

## Foundry Project Manager

- **GUID:** `eadc314b-1a2d-4efa-be10-5d325db5065e` (alias of *Azure AI Project Manager*)
- **Scope:** Project.
- **What it grants:** Everything in `Foundry User` **plus** project management actions **plus** a **conditional** `Microsoft.Authorization/roleAssignments/write` scoped so it can only assign the `Foundry User` role inside the project. Cannot assign itself, cannot create sub-projects at the account, cannot manage the account resource.

### Purpose

The "team lead" role. Whoever runs a particular project's developer team can onboard other builders by granting them `Foundry User` inside that project &mdash; without needing subscription Owner or Foundry Owner.

### Assign it to

| Assignee | When |
|---|---|
| **Team lead / project admin** who owns a specific Foundry project. | They need to onboard builders. |
| An automation SP that runs an onboarding workflow (e.g. HR + Entra group sync). | Programmatic project membership management. |

### Do NOT assign it at account scope

Doing so effectively promotes them across every project. If they need cross-project rights, use `Foundry Account Owner` or `Foundry Owner` instead.

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry Project Manager** | `test_role_definitions.py` | GUID + role name. |
| **AS-01/project-admin**           | `test_assignments.py`      | Persona SP has ONLY this role at project scope. |
| **CTRL-ADMIN-01**                 | `test_controls.py`         | Persona can create a `Foundry User` role assignment on the project (the conditional roleAssignments/write path works). |

---

## Foundry Account Owner

- **GUID:** `e47c6f54-e4a2-4754-9501-8e0985b135e1` (alias of *Azure AI Account Owner*)
- **Scope:** Account (Foundry resource).
- **What it grants:** Full management over **the specific Foundry account resource** &mdash; create/modify projects inside it, manage capability hosts, deployments (subject to Azure Policy), diagnostic settings, connections. Conditionally assign `Foundry User`, ACR, and monitoring roles. Does **NOT** grant permission to create new Foundry accounts elsewhere in the subscription or resource group.

### Purpose

The IT/platform-operator role for **an existing Foundry account**. Distinguishes "day 2 operations of an already-provisioned account" from "provision new Foundry accounts" (which the customer explicitly forbids &mdash; all provisioning goes through Bicep in the pipeline).

### Assign it to

| Assignee | When |
|---|---|
| **Platform team SPs** running day-2 ops (agents troubleshooting, capability host reconciliation, model routing changes at APIM). |
| **AzureAI/foundry landing-zone automation identities** that patch tags, diag settings, or connections on an already-created account. |

### Do NOT assign it to

- Anyone who should be able to spin up a new Foundry account &mdash; account creation must be Bicep-only via subscription Owner in the pipeline.

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry Account Owner** | `test_role_definitions.py` | GUID + role name. |
| **AS-01/platform**              | `test_assignments.py`      | Persona SP has ONLY this role at account scope. |
| **CTRL-PLAT-01a**               | `test_controls.py`         | GET account succeeds (management read). |
| **CTRL-PLAT-01b**               | `test_controls.py`         | PATCH tag on account succeeds (management write). |
| **CTRL-PLAT-01c**               | `test_controls.py`         | PUT of a NEW account at RG scope is denied 401/403 &mdash; proves the role cannot create new Foundry accounts. |

---

## Foundry Owner

- **GUID:** `c883944f-8b7b-4483-af10-35834be79c4a` (alias of *Azure AI Owner*)
- **Scope:** Account.
- **What it grants:** Everything Foundry Account Owner grants **plus** full data-plane rights inside every project of the account &mdash; i.e., Account Owner &cup; Foundry User across all projects. Conditionally assign `Foundry User`, ACR, and monitoring roles.

### Purpose

Microsoft's language: *"highly privileged self-serve role designed for digital natives."* It's the closest built-in role to "I own this entire Foundry account and every project inside it, and I want to build in them too." Prefer separating `Foundry Account Owner` (ops) + `Foundry User` on specific projects (build) when you have segregated duties.

### Assign it to

| Assignee | When |
|---|---|
| A **single-team, self-serve Foundry** where ops and dev are the same person. |
| Break-glass identity for a Foundry account &mdash; document + monitor tightly. |

### Do NOT assign it to

- Any principal that should not be able to build inside every project &mdash; use Account Owner + per-project Foundry User instead.

### Tests in this harness

| Test ID | File | Asserts |
|---|---|---|
| **RD-01/Foundry Owner** | `test_role_definitions.py` | GUID + role name. |

We intentionally do **not** provision a Foundry Owner persona SP &mdash; the harness demonstrates the separation-of-duties pattern (Account Owner for ops, Foundry User for builders) rather than the combined role.

---

## Assigning the roles

**CLI (recommended for individual users like Joe):**

```bash
SCOPE="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/projects/<project>"

az role assignment create \
  --assignee-object-id <principal-oid> \
  --assignee-principal-type User \      # or ServicePrincipal, Group
  --role "53ca6127-db72-4b80-b1b0-d745d6d5456d" \   # Foundry User
  --scope "$SCOPE"
```

**Bicep (used by this deployment for the 6 persona SPs):** see `main.bicep` and the reusable module `../../modules/iam/role-assignment-foundryProject.bicep` (project scope) or `role-assignment-cognitiveServices.bicep` (account scope). Both modules accept every Foundry role name listed above as `role` and resolve to the correct GUID.

---

## References

- **Microsoft Learn &mdash; RBAC for Microsoft Foundry:** https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry
- **AI + Machine Learning built-in roles (exact definitions):** https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning
- **Foundry role catalog (community):** https://rbac-catalog.dev/roles/142bfaed-a13f-4c2d-bed2-6db62c4a1009/foundry-project-runtime-user
- Local: `tests/output/foundry-role-definitions.actual.json` &mdash; the six role definitions as read from ARM at test time.
- Local: `tests/output/rbac-validation-results.json` &mdash; per-test evidence rows.
- Local: `docs/rbac-validation-report.html` &mdash; human-readable roll-up of all tests.
