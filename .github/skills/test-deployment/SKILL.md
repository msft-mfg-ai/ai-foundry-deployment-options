---
name: test-deployment
description: >
  Run the live gateway/integration test suite against the most recently
  deployed `options-infra/*` option. Auto-detects which option was deployed
  last (via `.azure/` env mtimes and the current working directory), loads
  the correct azd environment (`azd env get-values` from the option's
  `defaultEnvironment`), populates the test suite's `.env`, and runs `uv run
  pytest`. Use when the user says "test the deployment", "run gateway
  tests", "test what I just deployed", "smoke test the last deploy", "run
  pytest against the gateway", "verify the deployment", "test ai-gateway",
  or similar.
---

# Test the last-deployed option

Run the live integration tests bundled with an `options-infra/<option>/tests/`
suite against whichever deployment the user most recently ran, using the
azd-managed environment values in `.azure/<env>/.env`.

## Which options have tests

Only these options currently ship a live test suite. If the detected option
isn't one of them, tell the user and stop (or ask which option to test).

| Option | Suite | What it exercises |
|---|---|---|
| `options-infra/ai-gateway-quota/tests/` | `test_gateway.py`, `test_agent_service.py`, `test_priority_gateway.ipynb` | Full gateway: mode detection (open vs quota), model routing, priority/failover, contract JWT enforcement, config endpoint. Auto-skips `@pytest.mark.quota` tests when the gateway is in open mode. |
| `options-infra/ai-gateway-pe/tests/` | `test_realtime_gateway.py` | Realtime (WebSocket) `onHandshake` routing via both `openai` SDK and raw `websockets`. Skips cleanly when no `*realtime*` deployment is present. |

## Detection algorithm — run in order, stop at the first match

1. **Explicit user hint.** If the user names an option (e.g. "test
   ai-gateway-quota"), use it. Skip to Step 4.
2. **CWD-based.** If the current working directory is inside
   `options-infra/<option>/…`, use that `<option>`.
3. **Most recently deployed.** Rank options by the newest mtime under
   their `.azure/<env>/.env` file:
   ```bash
   ls -1t options-infra/*/.azure/*/.env 2>/dev/null | head -5
   ```
   Pick the top result whose option has a `tests/` directory. Show the top
   3 candidates and confirm with `ask_user` if there's ambiguity or the
   winner isn't obvious (e.g. multiple envs touched the same day).
4. **Resolve the azd environment.** Read
   `options-infra/<option>/.azure/config.json` for
   `defaultEnvironment`. Override only if the user explicitly names a
   different env.

## Running the tests

Do all of the following from `options-infra/<option>/`:

```bash
cd options-infra/<option>

# Copy azd env values into the tests/.env the suite reads.
# `azd env get-values` masks secrets as "******" and (as of azd 1.27) has no
# --no-mask flag, so copy the raw .env file directly — it stores unmasked
# values on disk and is the same file azd itself reads.
env_name="$(jq -r .defaultEnvironment .azure/config.json)"
cp ".azure/${env_name}/.env" tests/.env

cd tests
uv sync
uv run pytest -v
```

**Do not** commit `tests/.env` — it's git-ignored, but double-check with
`git status` before finishing. If it isn't ignored yet, add it to
`tests/.gitignore` instead of leaving it tracked.

## azd invocation rules (repo convention)

Always prefix `azd` with `AZD_DISABLE_AGENT_DETECT=1` when running from an
AI agent. Without it, azd auto-detects the coding agent and silently
switches to `--no-prompt`, which breaks `azd env select` when the env
requires reconfirmation.

## Auth prerequisites

Both suites use `DefaultAzureCredential` for the caller identity:

```bash
az login --tenant "$(grep '^TENANT_ID=' tests/.env | cut -d'"' -f2)"
```

The `ai-gateway-quota` suite can also use `CLIENT_ID` + `CLIENT_SECRET` from
the azd env (populated by `preprovision-*` hooks when the deployment
provisions per-team app registrations — e.g. `TEAM_ALPHA_APP_ID` /
`TEAM_ALPHA_SECRET`). If you want a specific team's identity, override
`CLIENT_ID` / `CLIENT_SECRET` in `tests/.env` before running pytest.

## Common overrides

| Env var | Default | When to override |
|---|---|---|
| `TEST_MODEL` | `gpt-4.1-mini` | Set to a model actually present in `FOUNDRY_INSTANCES_JSON` if the default isn't deployed. Suite auto-skips missing models. |
| `TEST_FAILOVER_MODEL` | = `TEST_MODEL` | Set to exercise cross-region failover. |
| `TEST_CONTRACT` | `Team Alpha` | Set for quota-mode contract-scoped tests. |
| `APIM_SKU` | (unset) | Set to `BasicV2`/`StandardV2`/`Premium` to correctly gate the `openai-api-v1` test. |
| `APIM_SUBSCRIPTION_KEY` / `APIM_API_KEY` | (unset) | Only if the gateway requires an APIM key. |

## Subset runs

```bash
uv run pytest -m "not quota"                            # open-mode-only suite
uv run pytest test_gateway.py::test_inference_passthrough -v
uv run pytest -s test_realtime_gateway.py               # ai-gateway-pe
```

## Reporting back

On completion, summarise:

- Which option and azd env were selected, and how (CWD / mtime / explicit).
- APIM gateway URL under test (`APIM_GATEWAY_URL` from the loaded env).
- Test totals (passed / failed / skipped) and skip reasons for any
  auto-skipped groups (open mode, missing model, wrong SKU).
- For failures, include the pytest short traceback for each.

## Failure playbook

- **All tests fail with 401/403** → likely token audience mismatch; verify
  `TENANT_ID` matches the APIM JWT policy tenant and `az account show`
  points at the right tenant.
- **All tests fail with 404 on `/inference/…`** → gateway API surface not
  deployed. Re-check `azd env get-values` and confirm `APIM_GATEWAY_URL`
  points at the actual APIM instance from the last deploy.
- **`model` fixture skipped** → `TEST_MODEL` not in the gateway's
  discovered models. Inspect `FOUNDRY_INSTANCES_JSON` in the azd env and
  choose a real deployment name.
- **`APIM_GATEWAY_URL` empty after `azd env get-values`** → the deployment
  didn't complete or hasn't emitted outputs; re-run `azd up` before
  testing.
- **Realtime tests all skip** → no `*realtime*` model deployment behind
  the gateway. Expected on non-realtime deployments.
- **All realtime tests fail with `HTTP 403 "APIM can be reached only from
  inside your virtual network"`** → the deployment is private-endpoint only
  (typical for `ai-gateway-pe`). The tests can't be executed from a
  developer machine outside the VNet — this is a network reality, not a
  bug. Report the failure and stop; do not "fix" the tests. To actually
  run them, execute from a VM in the peered VNet or via a Bastion/jumpbox.
