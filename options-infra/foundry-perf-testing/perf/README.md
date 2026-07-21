# Perf harness — Foundry perf-testing

k6 load test with a ramping VU sweep (1 → 100 concurrent) against each of the
three agent variants. All three hit the SAME MCP server, use the SAME model
(`gpt-5-mini`), and receive the SAME 10 canned support prompts (each of which
forces at least one MCP tool call).

## Files

| File | Purpose |
|------|---------|
| `k6-load.js` | The k6 script. `VARIANT=custom\|hosted\|prompt` selects the target endpoint. Emits JSON to `results/<variant>-<timestamp>.json`. |
| `prompts.json` | 10 canned prompts (open/fetch/close case scenarios). |
| `provision-sessions.sh` | Pre-creates N hosted-agent sandbox sessions and writes `sessions.json`. Required before the hosted-variant run. |
| `cleanup-sessions.sh` | DELETEs every session in `sessions.json`. |
| `run.sh` | Runs all three variants in sequence, pulling endpoints + AAD token from `azd env`. Auto-provisions/cleans sessions around the `hosted` variant. |

## Hosted-agent session pinning (single-session baseline)

Foundry hosted agents run in **per-session sandbox VMs**, capped at **50 concurrent
active sessions per region per subscription** (error code
`regional_session_quota_exceeded`). Sessions and conversations are distinct
concepts — reusing `agent_session_id` reuses the sandbox VM without replaying
model history.

**Baseline scenario (default): all VUs share a single session.** We
pre-provision one sandbox via `provision-sessions.sh`, write its id to
`sessions.json`, and every k6 request sends the same `agent_session_id` in the
Responses body (per the [`manage-hosted-sessions`
doc](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-sessions)).
This removes all sandbox-spin-up variance so we're measuring pure
model + APIM + Foundry-Responses overhead.

**Multi-session behaviour is a separate scenario planned as a follow-up.**
`HOSTED_SESSION_POOL` is still overridable if you want to sanity-check that
`>1` works, but the k6 script always picks slot `0`:
```
HOSTED_SESSION_POOL=1 perf/run.sh hosted   # default
```

## Ramping-VU stages

| Stage | Duration | Target VUs |
|-------|----------|------------|
| Warm-up | 30 s | 1 |
| Ramp | 2 m | 5 |
| Ramp | 2 m | 20 |
| Ramp | 2 m | 50 |
| Ramp | 2 m | 100 |
| Cool-down | 1 m | 0 |

Total ≈ 11 minutes per variant, ≈ 33 minutes for the full sweep.

## Interpreting results

For each variant we get:
- `agent_latency_<variant>` — end-to-end wall time from `POST` to response
- `tool_calls_<variant>` — total MCP tool calls counted across all responses
- `agent_errors_<variant>` — non-2xx responses

Expected ordering based on `session/files/perf-baseline.md`:
- **Custom** < **Hosted** < **Prompt** on p50 latency
- Delta between Hosted and Custom ≈ the ~1.15 s Foundry Responses overhead
  measured in the byom-canary baseline
- All three degrade sharply at the 50 → 100 VU stage on `gpt-5-mini` because
  its APIM p99 tail is already 15+ seconds under low load

Correlate with App Insights (`AppRequests | where AppRoleName in
('support-agent-custom','support-agent-hosted','agentsv2')`) for the
latency-budget breakdown.
