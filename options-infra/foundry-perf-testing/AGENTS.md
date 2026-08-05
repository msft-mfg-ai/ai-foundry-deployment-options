# Agent Instructions — `options-infra/foundry-perf-testing`

Scope-specific rules for the perf-testing deployment (Prompt vs Hosted vs
Custom Foundry agents + FastMCP + APIM BYOM). Read this before editing any
file under this directory.

## Always smoke-test locally before `azd deploy`

Deploy round-trips (build → push → ACA revision → replica wait) take ~30s
minimum and burn perf-run momentum. **Every service edit must be validated
locally before deploy.**

### Python services (`services/mcp-server`)

```sh
cd services/mcp-server
uv sync                          # once, if deps changed
uv run python -m app.main &      # or: uv run mcp-server
sleep 2
curl -sS http://localhost:8000/health
curl -sS -X POST http://localhost:8000/mcp/ \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
kill %1
```

Any startup-time TypeError / import error / kwarg-removed error surfaces
in < 3 seconds — a broken FastMCP kwarg (e.g. `stateless_http` moving off
the constructor) will crash locally exactly the way it crashes in ACA, and
you'll catch it before pushing a `NotRunning` revision.

### C# services (`services/support-agent-custom`, `services/support-agent-hosted`, shared `services/support-agent-shared`)

```sh
cd services/support-agent-custom
dotnet build -c Release --nologo
# For a full runtime smoke, set the env vars from `azd env get-values` and
# `dotnet run` locally against the deployed MCP + Foundry.
```

At minimum run `dotnet build` on any shared code path before deploying —
compile errors are cheap to catch locally.

## Don't change library APIs in the same commit as a deploy

`fastmcp` and `mcp` (jlowin's fork vs official) have overlapping-but-not-
identical APIs. If you're moving between them, or updating either, land the
change locally and prove it works before touching `azd deploy`.

## MCP scaling

FastMCP with default (stateful) mode holds `Mcp-Session-Id` per client — if
ACA rotates replicas, cached client sessions return `HTTP 404 session
expired`. This directory uses `stateless_http=True` on `mcp.run(...)` so
ACA can scale freely (min 1 / max 5 in `main.bicep`). Do NOT reintroduce
stateful mode without pinning `scaleMaxReplicas: 1`.

## Perf harness

- `perf/run.sh` — runs k6 for one or more variants; tees to `results/<v>-<ts>.log`
  and extracts a clean per-iteration JSONL for the audit trail.
- `K6_PROFILE=short perf/run.sh custom hosted prompt` — 2-min ramp for smoke.
- No `K6_PROFILE` = full 9m30s production ramp.
- Every k6 iteration emits a `__ITER__{...}` console line captured into
  `results/*.jsonl` with `{v, vu, it, status, ms, ok, client_request_id,
  request_id, apim_request_id, traceparent, tool_calls, prompt, reply}`. Use
  these IDs to correlate a failing iteration with app, APIM, and Foundry logs.

## APIM front-door

All three variants route through the co-deployed APIM (`apim-ai-<token>`,
Basicv2, public). Foundry BYOM connection `apim-<token>-openai-s-for-<project>`
points at the **`inference-mock`** API by default (canned chat completions
via `<return-response>`, no backend hop) — this isolates agent-framework
overhead from model latency. Switch to `'inference'` in
`main.bicep`'s `foundry_connections.inferenceApiName` to run against the
real Foundry model.

## After a redeploy that fixed a bug, restart the agent processes

The C# `support-agent-*` processes cache one long-lived `IMcpClient` per
process. If MCP was broken, those processes may hold dead session state —
bounce them with:

```sh
RG=rg-foundry-perf-testing
REV=$(az containerapp revision list -n support-agent-custom -g $RG \
  --query "[?properties.active].name" -o tsv | head -1)
az containerapp revision restart -n support-agent-custom -g $RG --revision "$REV"
```

Hosted-agent sandbox processes recycle on inactivity so no explicit restart
is required (a few warmup errors may still appear in the first ~20s).
