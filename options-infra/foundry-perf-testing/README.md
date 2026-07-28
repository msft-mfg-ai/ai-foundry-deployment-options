# Foundry Perf Testing — Prompt vs Hosted vs Custom agent

Baseline infrastructure + three agent variants for measuring end-to-end latency
of the same customer-support use case across Azure AI Foundry hosting patterns.

## Scenario

A single **customer-support agent** answers user questions by calling a
**FastMCP** case-management server. The MCP server exposes:

- `open_case(subject, description) -> case_id`
- `close_case(case_id, resolution) -> ok`
- `fetch_case(case_id) -> {status, subject, description, notes}`
- Skill/prompt resource `case-management-workflow` describing when to call which tool

The **same** agent (same system prompt, same MCP endpoint, same model) is
implemented **three** ways:

| # | Variant | Where it runs | Auth to model |
|---|---------|---------------|---------------|
| 1 | **Prompt agent** | Foundry (declarative) | Platform-managed |
| 2 | **Hosted agent** | Foundry container | `AIProjectClient.get_openai_client()` |
| 3 | **Custom agent** | ACA container | `AzureOpenAIClient` → `/openai/v1/` via UAMI |

Variants 2 and 3 share a single C# class library (`support-agent-shared`) so
the only difference between them is the request entrypoint.

## Topology

- Public Foundry account (`publicNetworkAccess=Enabled`)
- VNet with three subnets:
  - `agent-subnet` — delegated to `Microsoft.app/environments`, wired into Foundry
  - `aca-subnet` — delegated to `Microsoft.app/environments`, hosts the ACA env
  - `pe-subnet` — private endpoints (none used by default)
- One project, one capability host, **no BYO storage/search/cosmos** (matches
  `foundry-byo-vnet-no-dependencies`)
- Single `gpt-5-mini` GlobalStandard model deployment
- ACR (Premium, public) for hosted-agent + custom-agent + MCP images
- ACA environment (Consumption workload profile) for MCP server + custom agent
- Log Analytics + Application Insights shared across all three variants for
  like-for-like OpenTelemetry traces
- User-assigned MI for the custom-agent ACA app, granted
  **Cognitive Services OpenAI User** at account scope and **Azure AI User** at
  project scope

## Deployment

```bash
cd options-infra/foundry-perf-testing
AZD_DISABLE_AGENT_DETECT=1 azd up      # provisions + deploys all three services
```

The `azd up` flow:
1. `preprovision` — seeds `CHAT_MODEL=gpt-5-mini` if unset
2. `provision` — Bicep deploys VNet, Foundry, ACR, ACA env, both ACA apps
   (placeholder image), MI, role assignments
3. `deploy` — azd builds/pushes each service container:
   - `mcp-server` → ACA `mcp-server` app
   - `support-agent-custom` → ACA `support-agent-custom` app
   - `support-agent-hosted` → registered as a Foundry hosted agent
4. `postprovision` — prints endpoints + next-step commands

After that, seed the declarative prompt agent (`scripts/seed-prompt-agent.sh`)
and run the load-test harness (`perf/run.sh`).

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `chatModelName` | `gpt-5-mini` | Model deployment name |
| `chatModelVersion` | `2025-08-07` | Model version |
| `chatModelCapacity` | `50` | GlobalStandard capacity (K TPM units) |

All three are read from env vars (`CHAT_MODEL`, `CHAT_MODEL_VERSION`,
`CHAT_MODEL_CAPACITY`) by `main.bicepparam`.

## Outputs

| Output | Notes |
|--------|-------|
| `PROJECT_ENDPOINT` / `FOUNDRY_PROJECT_ENDPOINT` | Foundry project data-plane endpoint |
| `FOUNDRY_ACCOUNT_ENDPOINT` | Account endpoint (used by custom agent for BYOK-style `/openai/v1/` calls) |
| `MCP_SERVER_URL` | `https://mcp-server.<env-domain>/mcp` |
| `SERVICE_SUPPORT_AGENT_CUSTOM_ENDPOINT` | Custom-agent ACA FQDN |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | For `azd deploy` |
| `AZURE_AI_PROJECT_ID` | Required by the `azure.ai.agents` extension |
| `APP_IDENTITY_CLIENT_ID` | Custom-agent MI client ID (consumed inside the ACA container) |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Shared across all three variants |

## Perf methodology

See `perf/README.md`. tl;dr: k6 ramps concurrent VUs from 1 → 100 against each
of the three agent endpoints with the same 10-prompt corpus (each forces ≥ 1
MCP tool call), and emits per-stage p50/p95/p99 + error rate + tool-call
counts. Results are correlated with App Insights traces to break latency down
into model / orchestration / MCP layers.

The `session/files/perf-baseline.md` note (from the byom-canary hosted-agent
analysis) sets the expected floor at ≈ 2.9 s per single-turn hosted-agent
invocation (1.7 s APIM/model + 1.15 s Foundry-Responses overhead + 50 ms
agentserver framing). The **custom** variant is expected to shave off the
~1.15 s Foundry-Responses overhead by pointing `AzureOpenAIClient` at
`/openai/v1/` directly.
