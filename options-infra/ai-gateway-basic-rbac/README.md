# AI Gateway Basic + Foundry RBAC validation harness

Forked from [`ai-gateway-basic`](../ai-gateway-basic/) to **prove** the Foundry access model the customer requires:

> Builders (`Foundry User` at project scope) can build agents, tools, knowledge, guardrails, evaluations, and workflows in a pre-provisioned project, but **cannot** self-provision Foundry accounts/projects, deploy models, create Logic Apps/MCP servers, assign roles, gain Contributor-like subscription access, use account keys to bypass RBAC, or publish agents to Microsoft Teams.

## What this option adds on top of `ai-gateway-basic`

| Change | Reason |
|---|---|
| `projectsCount = 1` | Simplifies the test surface. |
| `disableLocalAuth = true` on the Foundry account | Makes N-08 (key bypass) pass by design; builders use Entra ID tokens only. |
| New preprovision hook `preprovision-rbac-sps.{sh,ps1}` | Creates 5 persona SPs and writes `RBAC_SP_JSON` + secrets to azd env. |
| New postprovision hook `postprovision-write-tests-env.{sh,ps1}` | Exports azd env → `tests/.env` for pytest. |
| Bicep persona role assignments | Foundry role assigned per persona at project or account scope. |
| `tests/` pytest suite | Automates RD-01, AS-01, B-01..B-07, N-01..N-08, R-01..R-03, plus platform / project-admin control tests. |

## Personas

| Persona SP | Role assigned by Bicep | Scope |
|---|---|---|
| `sp-foundry-<env>-builder` | `Foundry User` | Project |
| `sp-foundry-<env>-runtime` | `Foundry Agent Consumer` | Project |
| `sp-foundry-<env>-platform` | `Foundry Account Owner` | Account (control test — cleaned up per run) |
| `sp-foundry-<env>-project-admin` | `Foundry Project Manager` | Project (control test) |
| `sp-foundry-<env>-none` | *(none)* | — (baseline) |

The subscription-owner user (`piotrkarpala_microsoft.com#EXT#@…`) runs `azd up`; SPs need Entra permission to create app registrations — the deployer must have at least `Application Developer` in the tenant.

## Prerequisites

- Same as `ai-gateway-basic`: at least one backing Foundry / Azure OpenAI resource ID in `EXISTING_FOUNDRY_RESOURCE_IDS` (or `OPENAI_RESOURCE_ID`).
- `az login` as the subscription owner.
- Tenant permission to create AAD app registrations (`Application Developer` or above).

## Deploy

```bash
cd options-infra/ai-gateway-basic-rbac
export EXISTING_FOUNDRY_RESOURCE_IDS="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>"
AZD_DISABLE_AGENT_DETECT=1 azd up
```

## Run the pytest suite

```bash
cd tests
uv sync
uv run pytest -v
```

The suite writes machine-readable evidence to `tests/output/rbac-validation-results.{json,csv}`.

### Result classification (matches `foundry-rbac-ghcp-implementation-spec.html`)

| Result | Meaning |
|---|---|
| **Pass** | Allowed builder op returned 2xx OR prohibited op returned 401/403/AuthorizationFailed before any resource was created. |
| **Fail** | Prohibited op succeeded, or an allowed core builder op failed. Exit code non-zero. |
| **ManualRequired** | No stable public API for this operation. See `docs/manual-ui-test-plan.md`. Not counted as Pass. |
| **Investigate** | The op failed for reasons unrelated to authorization (bad request, feature flag, network). Assertion fails; classify manually. |

## Manual UI / PIM tests (SimpleJoe)

Automated tests exercise service principals only. UI tests (UI-01..UI-13) require a real user with PIM group activation — use `SimpleJoe@MngEnvMCAP272273.onmicrosoft.com`. See [`docs/manual-ui-test-plan.md`](docs/manual-ui-test-plan.md) for the full checklist.

## Cleanup

```bash
azd down --purge --force
```

The `azd down` removes the deployed resources but does **not** delete the AAD app registrations for the persona SPs — clean those up manually with:

```bash
for persona in builder runtime platform project-admin none; do
  az ad app delete --id "$(az ad app list --display-name sp-foundry-<env>-$persona --query '[0].appId' -o tsv)" || true
done
```

## Files

```
ai-gateway-basic-rbac/
├── README.md                    # this file
├── azure.yaml                   # hooks: preprovision + rbac SPs, postprovision → tests/.env
├── main.bicep                   # forked from ai-gateway-basic + persona role assignments
├── main.bicepparam              # reads RBAC_SP_JSON from env
├── config/
│   └── role-definitions.expected.json   # RD-01 baseline (mandatory assertions)
├── docs/
│   ├── manual-ui-test-plan.md   # UI-01..UI-13 for SimpleJoe via PIM
│   ├── architecture.md
│   ├── evidence-template.csv
│   └── troubleshooting.md
└── tests/                       # pytest suite (isolated uv workspace)
    ├── pyproject.toml
    ├── conftest.py              # fixtures + evidence recorder
    ├── test_role_definitions.py # RD-01
    ├── test_assignments.py      # AS-01
    ├── test_builder_positive.py # B-01..B-07
    ├── test_builder_negative.py # N-01..N-08
    ├── test_runtime.py          # R-01..R-03
    └── test_controls.py         # platform / project-admin control tests
```
