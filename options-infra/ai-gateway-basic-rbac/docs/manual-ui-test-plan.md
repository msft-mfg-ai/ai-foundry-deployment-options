# Manual UI test plan (SimpleJoe + PIM)

Automated pytest only exercises service principals. UI-driven paths in Foundry (playground, tool attachment, knowledge, guardrails, Teams publish) need a real user. Use test user `SimpleJoe@MngEnvMCAP272273.onmicrosoft.com`.

## PIM setup (once)

Create five Entra ID groups (one per persona) and make Joe **eligible** for each via PIM for Groups. Each group gets exactly one Foundry role at the same scope Bicep applied to the SP:

| Group | Role | Scope |
|---|---|---|
| `grp-foundry-builder` | Foundry User | Project |
| `grp-foundry-runtime` | Foundry Agent Consumer | Project |
| `grp-foundry-platform` | Foundry Account Owner | Account (validation only) |
| `grp-foundry-project-admin` | Foundry Project Manager | Project |
| `grp-foundry-none` | — | — |

Activate **only one** persona at a time. Sign out/in to https://ai.azure.com between activations so Joe's token reflects the new assignment.

## Test cases

| ID | Persona | UI action | Expected |
|---|---|---|---|
| UI-01 | none | Open Foundry project | No access / insufficient permissions |
| UI-02 | builder | Create playground agent with APIM-exposed model | Agent created; runs in playground |
| UI-03 | builder | Add approved tool/skill from the curated catalog | Approved item usable; unapproved external endpoint hidden or blocked |
| UI-04 | builder | Create a knowledge source | Configurable via approved data access |
| UI-05 | builder | Create/update guardrail configuration | Works |
| UI-06 | builder | Run evaluation; view status/results | Works |
| UI-07 | builder | Build workflow with approved tools only | Works |
| UI-08 | builder | Try to create a new Foundry account/project | Button hidden, disabled, or 403 |
| UI-09 | builder | Try to deploy a new model | Unavailable/denied |
| UI-10 | builder | Try to create a Logic App or arbitrary MCP endpoint | Unavailable/denied |
| UI-11 | builder | Try to publish/deploy the agent into Microsoft Teams | Blocked; playground remains available |
| UI-12 | runtime | Open/call an assigned agent endpoint | Endpoint interaction works; build/admin UX absent |
| UI-13 | project-admin | Try publish + delegated access in validation scope | Works — confirms why this role is not a builder role |

## Evidence

For each executed UI test, record in `docs/evidence-template.csv`:

- Test ID (e.g. UI-02)
- Persona activated
- Screenshot / video path
- Foundry request-id from browser dev tools if visible
- Timestamp (UTC)
- Pass / Fail / Investigate
