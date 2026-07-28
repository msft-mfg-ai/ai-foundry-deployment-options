# Playwright UI tests — Foundry portal as an interactive user (default: Joe)

These tests complement the API/REST harness in `../tests/` by validating what
a Foundry User can and cannot do **from the Foundry portal**, running the
browser as an actual signed-in user (default: `SimpleJoe@MngEnvMCAP272273.onmicrosoft.com`
with `Foundry User` at project scope).

Storage state (cookies + local storage) is captured once via an interactive
login, then reused by every pytest run.

## Prerequisites

- `azd up` from the parent option has succeeded — this test suite reads
  `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `FOUNDRY_ACCOUNT_NAME`,
  `FOUNDRY_PROJECT_NAME`, `AZURE_TENANT_ID` from the sibling `../tests/.env`.
- The user under test already has an RBAC assignment on the target project
  (for Joe: `Foundry User` at project scope — assigned via `az role assignment
  create` after deploy).
- Local Chromium — installed automatically by `playwright install chromium`.

## First-time setup

```bash
cd options-infra/ai-gateway-basic-rbac/ui-tests
uv sync
uv run playwright install chromium
cp .env.example .env       # optionally tweak UI_USER_LABEL / project URL
uv run python auth_setup.py
# → a Chromium window opens; sign in as the user under test
# → press <Enter> in the terminal to save .auth/joe.json
```

## Run the tests

```bash
uv run pytest                 # headless, uses saved auth
uv run pytest --headed        # watch the browser drive
uv run pytest --headed --slowmo=250   # slow-motion debugging
```

Artifacts:
- `output/ui-validation-results.json` / `.csv` — per-test evidence rows.
- `test-results/` — Playwright traces / screenshots / video for any failure.

## What the tests cover

| ID   | Scenario | Assertion |
|------|----------|-----------|
| UI-01 | positive | Portal loads without a login redirect (auth state is valid). |
| UI-02 | positive | The user reaches the project overview page (no access-denied). |
| UI-03 | positive | The Agents / Playground nav entry is visible on the project. |
| UI-04 | negative | No "New project" / "Create project" control on Foundry home. |
| UI-05 | negative | No "Deploy model" button under Models + endpoints. |
| UI-06 | negative | No "Publish to Microsoft Teams / M365" surface. |

`UI-04..UI-06` prove the customer's forbidden actions are also hidden in the
UI, on top of the RBAC + Azure Policy layer already validated by `../tests/`.

## Auth state expiry

Foundry / AAD cookies live ~1 hour. If tests suddenly fail with URLs on
`login.microsoftonline.com`, just re-run `uv run python auth_setup.py`
to refresh `.auth/joe.json`.

## Running as a different user

1. Update `UI_USER_LABEL` in `.env`.
2. Delete `.auth/joe.json` (or change `STORAGE_STATE_PATH`).
3. Re-run `uv run python auth_setup.py` and sign in as the new user.
