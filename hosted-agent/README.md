# hosted-agent — Gateway Diagnostics Agent (Copilot SDK, Responses)

A **Microsoft Foundry [Hosted Agent](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agents)** that exposes the **OpenAI Responses protocol** and drives a **[GitHub Copilot SDK](https://github.com/github/copilot-sdk)** session under the hood. It ships with two capability surfaces:

1. **Copilot's built-in tools** — bash, file read/write/edit, web fetch. Use these for one-off probes (`curl -v`, `nslookup`, `dig`, `openssl s_client`, `cat`).
2. **A single custom `run_tests` function-calling tool** — wraps the APIM/Foundry pytest suite (`test_gateway.py`, etc.) and returns junit-parsed JSON. The model calls it whenever you ask to "test", "verify", "smoke", or "validate" a gateway deployment.

Because the agent runs *inside* the Foundry project's fabric, it can reach APIM/Foundry accounts that have `publicNetworkAccess=Disabled` — which is exactly the scenario a developer laptop can't touch.

## Environment variables

Set automatically by the Foundry platform / `azure.yaml`:

| Name | Source | Purpose |
|---|---|---|
| `FOUNDRY_PROJECT_ENDPOINT` | auto-injected by Foundry | Used to derive the OpenAI-v1 base URL for the Copilot SDK BYOK provider. |
| `AZURE_AI_MODEL_DEPLOYMENT_NAME` | `azure.yaml` env vars | Model deployment name the Copilot SDK routes through (default `gpt-5.4-mini`). |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | auto-injected | Tracing. Never declare in `azure.yaml`. |
| `COPILOT_CLI_EXTRACT_DIR` | `azure.yaml` | Points the SDK at the runtime pre-baked into the image. |
| `COPILOT_SKIP_CLI_DOWNLOAD=1` | `azure.yaml` | Blocks cold-start downloads from github.com (required in PE networks). |

Test-time defaults (overridable per `/responses` call by asking the agent, or programmatically via the `run_tests` tool's `env` param):

| Name | Purpose |
|---|---|
| `APIM_GATEWAY_URL` | Base URL of the target APIM. |
| `TENANT_ID` | AAD tenant for token acquisition. |
| `TEST_MODEL`, `TEST_FAILOVER_MODEL`, `TEST_CONTRACT`, `APIM_SUBSCRIPTION_KEY`, `APIM_SKU`, `APIM_REALTIME_URL` | Test-suite knobs — same names the `ai-gateway-quota` harness uses. |

## Auth model

The container uses `DefaultAzureCredential` inside the Foundry runtime (the platform mounts the agent's system-assigned managed identity). Rather than snapshotting a bearer token at session-create time, we hand the Copilot SDK a **`bearer_token_provider` callback** — the SDK's runtime invokes it whenever it needs a fresh token, so multi-turn tool sessions never carry a stale credential and 401s trigger a natural re-auth. No API key rotation, no key vault.

### Two paths to the model

Hosted agents get [implicit access](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-permissions#agent-access-beyond-defaults) to their own project for model inference **through the project endpoint** (the project MI proxies the call to the account-level deployment). The Copilot SDK doesn't know about Foundry connections or the project endpoint, so we bridge the gap in `_resolve_provider()`:

**Option A — through an APIM connection defined on the project (preferred; no account-scope RBAC needed).**
Set `APIM_CONNECTION_NAME=<connection-name>` in `azure.yaml`. At startup the handler calls `GET {FOUNDRY_PROJECT_ENDPOINT}/connections/<name>?api-version=v1&includeCredentials=true`, extracts `target` + `credentials`, and points the Copilot SDK provider at APIM. Reading connections uses the project endpoint (implicit access), so **no account-scope role assignment is required**. What you may still need:
- If the connection is `ApiKey`: nothing else — the key comes back with the connection.
- If the connection is `ProjectManagedIdentity`: the agent MI (from `azd ai agent show`) needs whatever role your APIM policy validates for AAD callers — typically `Cognitive Services OpenAI User` on the *backing Foundry account* that APIM proxies to, or an equivalent claim in an APIM ACL.

**Option B — BYOK straight to the Foundry account (no APIM in the loop).**
Leave `APIM_CONNECTION_NAME` unset. The handler builds a provider pointing at `https://{account}.services.ai.azure.com/openai/v1/`. This **bypasses the project endpoint proxy**, so the docs' "[Account-level access](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-permissions#account-level-access)" carve-out applies — grant the agent's Instance Identity MI `Cognitive Services OpenAI User` at the Foundry account scope:

```bash
MI=$(AZD_DISABLE_AGENT_DETECT=1 azd ai agent show gateway-test-agent \
  | awk '/Instance Identity Principal ID/{print $NF}')
SCOPE=$(az cognitiveservices account show -g <rg> -n <account> --query id -o tsv)
az role assignment create --assignee "$MI" --role "Cognitive Services OpenAI User" --scope "$SCOPE"
```

> `Azure AI Developer` looks like the natural choice but the [Foundry docs explicitly caution against it](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-permissions#roles-in-this-article) — that role is scoped to AML/Foundry hubs, not Foundry projects, and doesn't cover the account-level OpenAI endpoint. Stick with `Cognitive Services OpenAI User`.

Symptom if permissions are wrong: every `/responses` call returns a completed response whose text is `[agent error: Authentication failed with provider at https://…/ (HTTP 401)]`, and the container logs show `PermissionDenied — Principal does not have access to API/Operation`. RBAC propagation takes ~1–2 min.

> The Copilot SDK has no hook to inject a Python `OpenAI` / `httpx` client into the runtime. The Python `copilot` package is a JSON-RPC client (`copilot._jsonrpc`) that spawns the `copilot-cli` binary as a subprocess and proxies session events over stdio — model HTTP calls happen inside that runtime process, not in Python, so a Python client wouldn't sit in the request path even if you handed one in. `bearer_token_provider` works because it's a JSON-RPC callback the runtime makes back into Python (`hasBearerTokenProvider: true`). Everything else (URL rewrites, extra headers) has to be handled server-side, in the APIM policy.
