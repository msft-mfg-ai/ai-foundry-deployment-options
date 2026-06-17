# Realtime (WebSocket) gateway test

Exercises the APIM AI Gateway's realtime endpoint
(`{gateway}/inference/openai/realtime`) end-to-end with Entra ID auth, verifying
that the `onHandshake` routing policy accepts the WebSocket upgrade, routes to
the correct `*realtime*` backend, and completes a text round-trip.

## What it checks

For each transport it asserts the backend emits `session.created` and, after a
`response.create`, a `response.done`:

| Test | Transport | Use |
|---|---|---|
| `test_realtime_via_openai_sdk` | `openai` `AsyncAzureOpenAI` realtime client | matches Foundry / app code |
| `test_realtime_via_raw_websocket` | raw `websockets` connection | debug handshake / routing / auth |

Both tests **skip** (not fail) when no realtime model or gateway URL is
resolvable, so they are safe to run against a gateway that fronts no realtime
deployment.

## Prerequisites

- A backing Foundry instance with a `*realtime*` model deployed (e.g.
  `gpt-realtime` or `gpt-4o-realtime-preview`). Without it the WebSocket API
  isn't created and these tests skip.
- The gateway deployed from [`../`](../) (`azd up`), which emits
  `APIM_GATEWAY_URL` and `APIM_REALTIME_URL` outputs.
- `az login` — `DefaultAzureCredential` uses that identity, which must have
  access to the backing Cognitive Services account.

## Run

```bash
cd options-infra/ai-gateway-pe/tests
uv sync

az login
uv run pytest -s                          # both transports
uv run python test_realtime_gateway.py   # verbose single round-trip
```

## Configuration

Resolved automatically from the deployed azd environment (`../.azure/<env>/.env`
or `azd env get-value`). Override with environment variables:

| Variable | Purpose | Default |
|---|---|---|
| `APIM_GATEWAY_URL` | Gateway `https://` base (SDK transport) | from azd env |
| `APIM_REALTIME_URL` | Realtime `wss://` URL (raw transport) | derived from gateway URL |
| `REALTIME_MODEL` | Deployment name to target | first `*realtime*` in `FOUNDRY_INSTANCES_JSON` |
| `REALTIME_API_VERSION` | Azure OpenAI realtime API version | `2024-10-01-preview` |

The realtime URL uses the legacy form
`…/openai/realtime?api-version=<v>&deployment=<model>`; the gateway policy reads
the `deployment` (or `model`) query param to pick the backend.
