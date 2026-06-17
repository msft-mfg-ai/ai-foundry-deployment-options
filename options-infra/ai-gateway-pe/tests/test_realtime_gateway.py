"""
End-to-end test for the APIM AI Gateway realtime (WebSocket) API.

Connects to the gateway's realtime endpoint (`{gateway}/inference/openai/realtime`)
using Entra ID auth (DefaultAzureCredential) and runs a minimal text-in /
text-out turn against a `*realtime*` model deployment. Verifies that:

  - the WebSocket handshake is accepted (the onHandshake routing policy runs),
  - the backend `session.created` event arrives,
  - a `response.create` produces a `response.done` event.

Two transports are exercised:
  1. `test_realtime_via_openai_sdk` — the `openai` AsyncAzureOpenAI realtime
     client (what Foundry agents / app code use).
  2. `test_realtime_via_raw_websocket` — a raw `websockets` connection (useful
     for debugging handshake / routing / auth in isolation).

Config resolution (first match wins):
  - APIM gateway base URL: env `APIM_GATEWAY_URL`, else `.azure/<env>/.env`
    (`APIM_GATEWAY_URL`), else `azd env get-value APIM_GATEWAY_URL`.
  - Realtime model/deployment: env `REALTIME_MODEL`, else first deployment whose
    name contains "realtime" in `FOUNDRY_INSTANCES_JSON`.
  - Realtime wss URL (raw test): env `APIM_REALTIME_URL`, else derived from the
    gateway base URL.

Tests SKIP (not fail) when no realtime model or gateway URL can be resolved, so
the suite is safe to run against a gateway that fronts no realtime model.

Run:
    uv sync
    az login          # DefaultAzureCredential picks this up
    uv run pytest -s test_realtime_gateway.py
    # or run directly for a verbose single round-trip:
    uv run python test_realtime_gateway.py
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
from pathlib import Path

import pytest

# Entra ID scope for the backing Foundry / Cognitive Services account. The
# gateway validates the caller token (aud=cognitiveservices) and then swaps in
# its own managed-identity token for the backend.
COGNITIVE_SERVICES_SCOPE = "https://cognitiveservices.azure.com/.default"
DEFAULT_API_VERSION = os.environ.get("REALTIME_API_VERSION", "2024-10-01-preview")
PROMPT = "Reply with exactly: hello from the gateway."

# Directory of the deployed azd environment for this option (…/ai-gateway-pe).
OPTION_DIR = Path(__file__).resolve().parents[1]


def _read_azure_env() -> dict[str, str]:
    """Return key/value pairs from the active azd env's `.env` file, if any."""
    azure_dir = OPTION_DIR / ".azure"
    config = azure_dir / "config.json"
    env_name = None
    if config.exists():
        try:
            env_name = json.loads(config.read_text()).get("defaultEnvironment")
        except (ValueError, OSError):
            env_name = None
    candidates = []
    if env_name:
        candidates.append(azure_dir / env_name / ".env")
    # Fall back to any `.env` under `.azure/*/`.
    candidates.extend(sorted(azure_dir.glob("*/.env")))

    for env_file in candidates:
        if env_file.exists():
            return _parse_dotenv(env_file)
    return {}


def _parse_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        val = val.strip()
        # azd writes dotenv-quoted values with escaped inner quotes (\").
        if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
            val = val[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        values[key.strip()] = val
    return values


def _azd_env_get(key: str) -> str | None:
    try:
        out = subprocess.run(
            ["azd", "env", "get-value", key],
            cwd=OPTION_DIR,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return None
    # `azd env get-value <missing>` writes its error to stdout and exits 1.
    if out.returncode != 0:
        return None
    val = out.stdout.strip()
    return val or None


def _resolve_gateway_url(env: dict[str, str]) -> str | None:
    return (
        os.environ.get("APIM_GATEWAY_URL")
        or env.get("APIM_GATEWAY_URL")
        or _azd_env_get("APIM_GATEWAY_URL")
    )


def _resolve_realtime_model(env: dict[str, str]) -> str | None:
    if os.environ.get("REALTIME_MODEL"):
        return os.environ["REALTIME_MODEL"]
    for raw in (
        env.get("FOUNDRY_INSTANCES_JSON"),
        os.environ.get("FOUNDRY_INSTANCES_JSON"),
        _azd_env_get("FOUNDRY_INSTANCES_JSON"),
    ):
        if not raw:
            continue
        try:
            instances = json.loads(raw)
        except ValueError:
            continue
        for inst in instances:
            for dep in inst.get("deployments", []):
                name = dep.get("modelName", "")
                if "realtime" in name.lower():
                    return name
    return None


def _resolve_realtime_wss_url(env: dict[str, str], gateway_url: str | None) -> str | None:
    explicit = (
        os.environ.get("APIM_REALTIME_URL")
        or env.get("APIM_REALTIME_URL")
        or _azd_env_get("APIM_REALTIME_URL")
    )
    if explicit:
        return explicit
    if gateway_url:
        wss = gateway_url.replace("https://", "wss://").rstrip("/")
        return f"{wss}/inference/openai/realtime"
    return None


def _config():
    env = _read_azure_env()
    gateway_url = _resolve_gateway_url(env)
    model = _resolve_realtime_model(env)
    wss_url = _resolve_realtime_wss_url(env, gateway_url)
    return gateway_url, model, wss_url


@pytest.fixture(scope="session")
def gateway_config():
    gateway_url, model, wss_url = _config()
    if not model:
        pytest.skip(
            "No realtime model resolved (set REALTIME_MODEL or deploy a "
            "'*realtime*' model on a backing Foundry instance)."
        )
    if not gateway_url and not wss_url:
        pytest.skip(
            "No gateway URL resolved (set APIM_GATEWAY_URL / APIM_REALTIME_URL "
            "or run from a deployed azd environment)."
        )
    return {"gateway_url": gateway_url, "model": model, "wss_url": wss_url}


async def _run_openai_sdk_turn(gateway_url: str, model: str) -> dict:
    from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider
    from openai import AsyncAzureOpenAI

    azure_endpoint = f"{gateway_url.rstrip('/')}/inference"
    credential = DefaultAzureCredential()
    token_provider = get_bearer_token_provider(credential, COGNITIVE_SERVICES_SCOPE)

    client = AsyncAzureOpenAI(
        azure_endpoint=azure_endpoint,
        azure_ad_token_provider=token_provider,
        api_version=DEFAULT_API_VERSION,
    )

    saw_session_created = False
    saw_response_done = False
    transcript = []
    try:
        async with client.beta.realtime.connect(model=model) as conn:
            await conn.session.update(session={"modalities": ["text"]})
            await conn.conversation.item.create(
                item={
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": PROMPT}],
                }
            )
            await conn.response.create()
            async for event in conn:
                etype = event.type
                if etype == "session.created":
                    saw_session_created = True
                elif etype == "response.text.delta":
                    transcript.append(event.delta)
                elif etype == "error":
                    raise AssertionError(f"realtime error event: {event}")
                elif etype == "response.done":
                    saw_response_done = True
                    break
    finally:
        await client.close()
        await credential.close()

    return {
        "session_created": saw_session_created,
        "response_done": saw_response_done,
        "text": "".join(transcript),
    }


async def _run_raw_ws_turn(wss_url: str, model: str) -> dict:
    import websockets
    from azure.identity.aio import DefaultAzureCredential

    credential = DefaultAzureCredential()
    token = (await credential.get_token(COGNITIVE_SERVICES_SCOPE)).token
    # Legacy realtime URL form: ?api-version=…&deployment=<name>.
    url = f"{wss_url}?api-version={DEFAULT_API_VERSION}&deployment={model}"
    headers = [("Authorization", f"Bearer {token}")]

    saw_session_created = False
    saw_response_done = False
    transcript = []
    try:
        async with websockets.connect(url, additional_headers=headers) as ws:
            await ws.send(json.dumps({"type": "session.update", "session": {"modalities": ["text"]}}))
            await ws.send(
                json.dumps(
                    {
                        "type": "conversation.item.create",
                        "item": {
                            "type": "message",
                            "role": "user",
                            "content": [{"type": "input_text", "text": PROMPT}],
                        },
                    }
                )
            )
            await ws.send(json.dumps({"type": "response.create"}))
            async for raw in ws:
                event = json.loads(raw)
                etype = event.get("type")
                if etype == "session.created":
                    saw_session_created = True
                elif etype == "response.text.delta":
                    transcript.append(event.get("delta", ""))
                elif etype == "error":
                    raise AssertionError(f"realtime error event: {event}")
                elif etype == "response.done":
                    saw_response_done = True
                    break
    finally:
        await credential.close()

    return {
        "session_created": saw_session_created,
        "response_done": saw_response_done,
        "text": "".join(transcript),
    }


@pytest.mark.asyncio
async def test_realtime_via_openai_sdk(gateway_config):
    if not gateway_config["gateway_url"]:
        pytest.skip("APIM_GATEWAY_URL not resolved; SDK transport needs the https base URL.")
    result = await _run_openai_sdk_turn(gateway_config["gateway_url"], gateway_config["model"])
    print(f"\n[openai sdk] {result}")
    assert result["session_created"], "did not receive session.created from the realtime backend"
    assert result["response_done"], "did not receive response.done from the realtime backend"


@pytest.mark.asyncio
async def test_realtime_via_raw_websocket(gateway_config):
    if not gateway_config["wss_url"]:
        pytest.skip("No realtime wss URL resolved.")
    result = await _run_raw_ws_turn(gateway_config["wss_url"], gateway_config["model"])
    print(f"\n[raw ws] {result}")
    assert result["session_created"], "did not receive session.created from the realtime backend"
    assert result["response_done"], "did not receive response.done from the realtime backend"


async def _main() -> None:
    gateway_url, model, wss_url = _config()
    print(f"gateway_url = {gateway_url}")
    print(f"wss_url     = {wss_url}")
    print(f"model       = {model}")
    if not model:
        print("No realtime model resolved — set REALTIME_MODEL or deploy a *realtime* model.")
        return
    if gateway_url:
        print("\n--- openai sdk transport ---")
        print(await _run_openai_sdk_turn(gateway_url, model))
    if wss_url:
        print("\n--- raw websocket transport ---")
        print(await _run_raw_ws_turn(wss_url, model))


if __name__ == "__main__":
    asyncio.run(_main())
