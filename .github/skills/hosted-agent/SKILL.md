---
name: hosted-agent
description: |
  Deploy and invoke the Foundry Hosted Diagnostic Agent that lives in
  `hosted-agent/`. Use for any request phrased as "test / verify / smoke /
  validate a deployment", "check APIM from inside the network", "run the
  gateway tests against a PE-locked APIM / Foundry", "diagnose why my
  APIM/Foundry isn't reachable", "curl / nslookup / dig <something> from
  inside my Foundry project". The agent exposes the OpenAI Responses API,
  is powered by the GitHub Copilot SDK (BYOK to a Foundry model), and has
  bash + filesystem + `run_tests` tools available.
---

# Foundry Gateway Diagnostics Hosted Agent

Deploys `hosted-agent/` — a Foundry hosted agent that exposes the **Responses
protocol** and drives a **GitHub Copilot SDK** session with bash + filesystem +
`run_tests` tools.

## When to use this skill

- User asks to test/verify a deployment where APIM is PE-locked
  (`publicNetworkAccess=Disabled`) and laptop callers get HTTP 403 "APIM can
  be reached only from inside your virtual network".
- User wants to run curl/nslookup/dig probes against a private endpoint from
  inside the Foundry project's fabric.
- User asks to run the `ai-gateway-quota` / `ai-gateway-pe` pytest suite from
  Azure rather than their laptop.

## Environment variables

All auto-injected or set from `azure.yaml`:

- `FOUNDRY_PROJECT_ENDPOINT` — auto-injected by Foundry.
- `AZURE_AI_MODEL_DEPLOYMENT_NAME` — controls which model the Copilot SDK uses. Default `gpt-5.4-mini` (declared in `azure.yaml`).
- `COPILOT_CLI_EXTRACT_DIR=/opt/copilot-runtime` — points at the pre-baked runtime.
- `COPILOT_SKIP_CLI_DOWNLOAD=1` — blocks cold-start downloads from github.com.
- Optional test-time defaults: `APIM_GATEWAY_URL`, `TENANT_ID`, `TEST_MODEL`, `TEST_FAILOVER_MODEL`, `TEST_CONTRACT`, `APIM_SUBSCRIPTION_KEY`, `APIM_SKU`, `APIM_REALTIME_URL`.

## Deploy

```bash
cd hosted-agent
AZD_DISABLE_AGENT_DETECT=1 azd auth login
AZD_DISABLE_AGENT_DETECT=1 azd env new gateway-test-agent   # skip if env exists
AZD_DISABLE_AGENT_DETECT=1 azd env set AZURE_LOCATION norwayeast
AZD_DISABLE_AGENT_DETECT=1 azd up
```

If `azd up` errors with "extension version constraint": upgrade first:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd extension upgrade azure.ai.agents
AZD_DISABLE_AGENT_DETECT=1 azd extension upgrade microsoft.foundry
```

## Invoke — OpenAI Responses API shape

```bash
ENDPOINT=$(AZD_DISABLE_AGENT_DETECT=1 azd env get-value AZURE_AI_PROJECT_ENDPOINT)
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)

curl -sS -X POST "$ENDPOINT/agents/gateway-test-agent/endpoint/protocols/responses?api-version=v1" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "input": "Run the gateway suite against APIM_GATEWAY_URL=<url> (TENANT_ID=<tid>, TEST_MODEL=<model>). Summarize.",
        "stream": false
      }' | jq .
```

For streaming set `"stream": true` and pipe through `sse-decoder` or read SSE frames.

## Tools the agent has

- **Bash / shell** (built-in) — `curl -v`, `nslookup`, `dig`, `openssl s_client`, `cat`, `ls`, `jq`.
- **File read / write / edit** (built-in) — inspect the pytest suite bundled with the agent.
- **`run_tests`** (custom function-calling tool) — runs the pytest gateway suite as a subprocess and returns junit-parsed JSON. Signature:
  - `tests: string[]` — pytest node-ids; default `["test_gateway.py"]`.
  - `env: object` — per-call env overrides.
  - `markers: string` — `-m` marker expression (`quota`, `foundry`, `realtime`).
  - `verbose: bool` — include full junit XML + stderr in result.

## Prompting tips

- Tell the agent the exact `APIM_GATEWAY_URL`, `TENANT_ID`, and `TEST_MODEL` (or set them in `azure.yaml` env vars if this is the only target).
- If you only want a specific test, say so: "Run only `test_gateway.py::test_unknown_model_rejected`."
- For DNS/TLS diagnostics, ask directly: "curl -v the APIM discovery endpoint at ... and report the TLS SAN list" — the bash tool answers without invoking `run_tests`.

## Common failure modes

| Symptom | Meaning | Fix |
|---|---|---|
| Caller `POST /responses` → 401 | Wrong token audience. | Use `--resource https://ai.azure.com`. |
| Tool output `AssertionError: status=401` | Agent's Entra app not in APIM JWT allow-list. | Add `appid` to `caller-identity-fragment.xml` claims. |
| Tool output `AssertionError: status=403` | Policy rejected the agent's identity. | Grant `Cognitive Services User` on the Foundry account and check APIM ACL claims. |
| Every response returns `[agent error: Authentication failed with provider at ... (HTTP 401)]` | Agent BYOK's to the account-level OpenAI endpoint, bypassing the project-endpoint proxy — [implicit permissions don't cover this path](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/hosted-agent-permissions#account-level-access). | Grant `Cognitive Services OpenAI User` at the Foundry account scope to the principal from `azd ai agent show gateway-test-agent` (see README "One-time RBAC after first deploy"). Do NOT use `Azure AI Developer` — docs explicitly warn it's the wrong role for this. |
| `deployment not found` from the model | `AZURE_AI_MODEL_DEPLOYMENT_NAME` doesn't match `azure.yaml` deployments. | Sync both. |

## Never do

- Do not commit `hosted-agent/.azure/` — it's git-ignored for a reason (contains subscription/env metadata).
- Do not add API keys to `azure.yaml` — the agent uses AAD via `DefaultAzureCredential`.
- Do not remove `COPILOT_SKIP_CLI_DOWNLOAD=1` — required so PE-network deploys don't cold-start-download from github.com.
