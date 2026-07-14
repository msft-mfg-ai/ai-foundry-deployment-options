# Copyright (c) Microsoft. All rights reserved.

"""Gateway Test Agent — Bring Your Own Responses agent (Python, Copilot SDK).

Hosted Foundry agent that exposes the OpenAI Responses protocol and drives a
GitHub Copilot SDK session under the hood. The Copilot CLI runtime ships
with built-in bash + filesystem tools (curl, nslookup, dig, cat, ls, edit),
so the agent can already probe endpoints and inspect files from inside the
Foundry project's network fabric with zero extra code. A single custom
function-calling tool — ``run_tests`` — wraps the APIM/Foundry pytest
suite that lives alongside this file.

Flow:

    POST /responses (from the Foundry runtime)
       -> ResponsesAgentServerHost.response_handler
          -> CopilotClient session (BYOK -> Foundry model, wire=responses)
             -> [optional] built-in bash/file tools (curl, nslookup, ...)
             -> [optional] custom run_tests tool (pytest subprocess)
          -> stream assistant deltas back over SSE

Required env vars (all auto-set by Foundry at deploy time via azure.yaml):

    FOUNDRY_PROJECT_ENDPOINT         auto-injected by the Foundry platform
    AZURE_AI_MODEL_DEPLOYMENT_NAME   which Foundry model to route through
    COPILOT_CLI_EXTRACT_DIR          where the pre-baked Copilot runtime lives

Optional (defaults for the run_tests tool; can be overridden per call):

    APIM_GATEWAY_URL, TENANT_ID, TEST_MODEL, ...
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shlex
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import httpx

from azure.identity.aio import DefaultAzureCredential

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponseEventStream,
    ResponsesAgentServerHost,
)

from copilot import CopilotClient
from copilot.session import PermissionHandler
from copilot.session_events import SessionEventType
from copilot.tools import define_tool
from pydantic import BaseModel, Field

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger("gateway-test-agent")


def _ensure_copilot_runtime() -> None:
    """Foundry hosted-agents run in a platform-provided container and may
    ignore the Dockerfile, so we cannot rely on the build-time
    ``python -m copilot download-runtime`` succeeding. Fetch the runtime
    lazily at process startup if it isn't already present.
    """
    path = os.environ.get("COPILOT_CLI_PATH")
    if path and Path(path).is_file() and os.access(path, os.X_OK):
        logger.info("Copilot CLI runtime already present at %s", path)
        return
    logger.info("Copilot CLI runtime missing; downloading now (one-time cold start)")
    # Ensure the SDK downloads *into* our chosen extract dir.
    os.environ.setdefault("COPILOT_CLI_EXTRACT_DIR", "/opt/copilot-runtime")
    Path(os.environ["COPILOT_CLI_EXTRACT_DIR"]).mkdir(parents=True, exist_ok=True)
    # Temporarily allow the download.
    prev_skip = os.environ.pop("COPILOT_SKIP_CLI_DOWNLOAD", None)
    try:
        rc = subprocess.run(
            [sys.executable, "-m", "copilot", "download-runtime"],
            check=False,
            capture_output=True,
            text=True,
            timeout=180,
        )
        logger.info(
            "download-runtime rc=%s stdout=%s stderr=%s",
            rc.returncode,
            rc.stdout[-500:],
            rc.stderr[-500:],
        )
    finally:
        if prev_skip is not None:
            os.environ["COPILOT_SKIP_CLI_DOWNLOAD"] = prev_skip
    # Re-check.
    if path and Path(path).is_file():
        logger.info("Copilot CLI runtime installed at %s", path)
    else:
        # Fall back: probe the SDK's default cache location and set
        # COPILOT_CLI_PATH so the client can find it without the extract-dir hint.
        for cache in [
            Path("/opt/copilot-runtime/copilot"),
            Path.home() / ".cache/github-copilot-sdk",
        ]:
            if cache.is_file():
                os.environ["COPILOT_CLI_PATH"] = str(cache)
                logger.info("Copilot CLI runtime found at fallback %s", cache)
                return
        raise RuntimeError(
            "Copilot CLI runtime download failed and no fallback binary was found."
        )


_ensure_copilot_runtime()

# ── Configuration ─────────────────────────────────────────────────────────────

FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT")
if not FOUNDRY_PROJECT_ENDPOINT:
    raise EnvironmentError(
        "FOUNDRY_PROJECT_ENDPOINT is not set. It is auto-injected by the "
        "Foundry platform inside a hosted container; set it manually for "
        "local dev."
    )

AZURE_AI_MODEL_DEPLOYMENT_NAME = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME")
if not AZURE_AI_MODEL_DEPLOYMENT_NAME:
    raise EnvironmentError(
        "AZURE_AI_MODEL_DEPLOYMENT_NAME is not set. Declare it in azure.yaml "
        "under the agent's environmentVariables."
    )


def _foundry_openai_base_url(project_endpoint: str) -> str:
    """Derive the OpenAI-v1 base URL for the Foundry account from the project
    endpoint the platform injects.

    Project endpoint shape:
        https://<account>.services.ai.azure.com/api/projects/<project>

    OpenAI v1 base URL shape (what the Copilot SDK BYOK provider wants):
        https://<account>.services.ai.azure.com/openai/v1/
    """
    from urllib.parse import urlparse

    parsed = urlparse(project_endpoint)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError(f"Malformed FOUNDRY_PROJECT_ENDPOINT: {project_endpoint!r}")
    return f"{parsed.scheme}://{parsed.netloc}/openai/v1/"


FOUNDRY_MODEL_URL = _foundry_openai_base_url(FOUNDRY_PROJECT_ENDPOINT)

# Optional: name of a Foundry project connection (category=ApiManagement)
# to route model calls through APIM instead of hitting the account-level
# OpenAI surface directly. When set, we resolve target + credentials from the
# named connection at startup via the project endpoint (agent's implicit
# access is sufficient) and cache the resulting provider config.
APIM_CONNECTION_NAME = os.environ.get("APIM_CONNECTION_NAME") or None

_credential = DefaultAzureCredential()
_AAD_SCOPE = "https://cognitiveservices.azure.com/.default"
_PROJECT_SCOPE = "https://ai.azure.com/.default"


def _token_provider(scope: str = _AAD_SCOPE):
    """Return an async callable the Copilot SDK awaits each time it needs a
    fresh AAD token. Delegates to the module-level async DefaultAzureCredential
    which handles its own cache + refresh. The SDK's BearerTokenProvider type
    accepts either ``str`` or ``Awaitable[str]``."""

    async def _get(_args=None) -> str:
        token = await _credential.get_token(scope)
        return token.token

    return _get


async def _fetch_connection(name: str) -> dict[str, Any]:
    """Fetch a Foundry project connection by name via the project endpoint."""
    url = (
        f"{FOUNDRY_PROJECT_ENDPOINT.rstrip('/')}/connections/"
        f"{name}?api-version=v1&includeCredentials=true"
    )
    token = await _credential.get_token(_PROJECT_SCOPE)
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Accept": "application/json",
    }
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.get(url, headers=headers)
    if r.status_code >= 400:
        raise RuntimeError(
            f"Failed to fetch APIM connection {name!r} from project "
            f"({r.status_code}): {r.text[:500]}"
        )
    return r.json()


async def _resolve_provider() -> dict[str, Any]:
    """Build a Copilot SDK ``provider`` dict for the model call.

    Two modes:
      * ``APIM_CONNECTION_NAME`` set → look up the named APIM connection on
        the Foundry project and route traffic through APIM. Reading the
        connection uses the agent's implicit project access.
      * otherwise → BYOK straight to the Foundry account's ``/openai/v1/``
        surface (requires ``Cognitive Services OpenAI User`` on the agent MI).
    """
    if not APIM_CONNECTION_NAME:
        return {
            "type": "openai",
            "base_url": FOUNDRY_MODEL_URL,
            "wire_api": "responses",
            "bearer_token_provider": _token_provider(_AAD_SCOPE),
        }

    payload = await _fetch_connection(APIM_CONNECTION_NAME)
    target = (payload.get("target") or "").rstrip("/")
    credentials = payload.get("credentials") or {}
    md = payload.get("metadata") or {}
    ctype = payload.get("type") or ""
    if ctype != "ApiManagement":
        logger.warning(
            "connection %r is type %r, expected ApiManagement",
            APIM_CONNECTION_NAME, ctype,
        )

    # APIM connections in this repo publish an OpenAI-shaped surface rooted
    # at ``target`` (typically ``https://apim.../inference``). The Copilot
    # SDK wants the ``/v1/`` root (it appends ``/responses`` itself).
    # `metadata.deploymentInPath` and `metadata.customHeaders` are hints for
    # legacy path-style callers and are not applicable here — model is read
    # from the request body and APIM policies handle any extra headers.
    base_url = f"{target}/v1/"

    provider: dict[str, Any] = {
        "type": "openai",
        "base_url": base_url,
        "wire_api": "responses",
    }

    cred_type = credentials.get("type") or ""
    if cred_type == "ApiKey":
        key = credentials.get("key")
        if not key:
            raise RuntimeError(
                f"APIM connection {APIM_CONNECTION_NAME!r} is ApiKey but no "
                "key was returned (includeCredentials denied?)"
            )
        provider["api_key"] = key
    elif cred_type in ("ProjectManagedIdentity", "ManagedIdentity", "AAD", ""):
        provider["bearer_token_provider"] = _token_provider(_AAD_SCOPE)
    else:
        raise RuntimeError(
            f"Unsupported APIM connection credential type: {cred_type!r}"
        )

    logger.info(
        "APIM connection resolved: name=%s type=%s base_url=%s auth=%s md_keys=%s",
        APIM_CONNECTION_NAME, ctype, base_url, cred_type, list(md.keys()),
    )
    return provider


# Where the pytest gateway suite lives (copied into the container image).
_TESTS_DIR = Path(__file__).parent.resolve()


# ── Custom tool: run_tests ────────────────────────────────────────────────────


class RunTestsParams(BaseModel):
    tests: list[str] | None = Field(
        default=None,
        description=(
            "Pytest node-ids or file paths to select (e.g. "
            "['test_gateway.py', 'test_gateway.py::test_unknown_model_rejected']). "
            "Omit or pass an empty list to run the entire test_gateway.py suite."
        ),
    )
    env: dict[str, str] | None = Field(
        default=None,
        description=(
            "Environment variables to override for this pytest run. Common keys: "
            "APIM_GATEWAY_URL, TENANT_ID, TEST_MODEL, APIM_SUBSCRIPTION_KEY, "
            "APIM_REALTIME_URL. Anything already in the container env stays as-is "
            "unless overridden here."
        ),
    )
    markers: str | None = Field(
        default=None,
        description=(
            "Pytest marker expression, passed to `-m`. Available markers: "
            "'quota', 'foundry', 'realtime'."
        ),
    )
    verbose: bool = Field(
        default=False,
        description="If true, include full junit XML and stderr in the result.",
    )


def _run_pytest_sync(params: RunTestsParams) -> dict[str, Any]:
    """Run the pytest suite as a subprocess and return junit-parsed JSON."""
    with tempfile.TemporaryDirectory(prefix="pytest-run-") as tmp:
        junit_path = Path(tmp) / "junit.xml"

        cmd: list[str] = [
            sys.executable,
            "-m",
            "pytest",
            "-v",
            "-ra",
            "--tb=short",
            f"--junitxml={junit_path}",
        ]
        if params.markers:
            cmd += ["-m", params.markers]
        tests = params.tests or ["test_gateway.py"]
        cmd += tests

        env = os.environ.copy()
        if params.env:
            env.update({k: str(v) for k, v in params.env.items()})

        logger.info("run_tests: %s", " ".join(shlex.quote(c) for c in cmd))
        proc = subprocess.run(
            cmd,
            cwd=str(_TESTS_DIR),
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
        )

        summary = {
            "passed": 0,
            "failed": 0,
            "errors": 0,
            "skipped": 0,
            "total": 0,
            "duration_s": 0.0,
            "exit_code": proc.returncode,
        }
        tests_out: list[dict[str, Any]] = []
        junit_xml_str = ""
        if junit_path.exists():
            junit_xml_str = junit_path.read_text(encoding="utf-8", errors="replace")
            try:
                root = ET.fromstring(junit_xml_str)
                suite = root.find("testsuite") if root.tag == "testsuites" else root
                if suite is not None:
                    summary["total"] = int(suite.get("tests", "0"))
                    summary["failed"] = int(suite.get("failures", "0"))
                    summary["errors"] = int(suite.get("errors", "0"))
                    summary["skipped"] = int(suite.get("skipped", "0"))
                    summary["passed"] = (
                        summary["total"]
                        - summary["failed"]
                        - summary["errors"]
                        - summary["skipped"]
                    )
                    summary["duration_s"] = float(suite.get("time", "0"))
                    for case in suite.findall("testcase"):
                        outcome = "passed"
                        message = ""
                        for kind in ("failure", "error", "skipped"):
                            child = case.find(kind)
                            if child is not None:
                                outcome = kind
                                message = (child.get("message") or "").strip() or (
                                    (child.text or "").strip()
                                )
                                break
                        tests_out.append(
                            {
                                "nodeid": f"{case.get('classname','')}::{case.get('name','')}",
                                "outcome": outcome,
                                "time_s": float(case.get("time", "0")),
                                "message": message,
                            }
                        )
            except ET.ParseError as e:  # pragma: no cover — defensive
                logger.warning("failed to parse junit xml: %s", e)

        result: dict[str, Any] = {"summary": summary, "tests": tests_out}
        if params.verbose:
            result["junit_xml"] = junit_xml_str
            result["stderr"] = proc.stderr[-4000:]
            result["stdout"] = proc.stdout[-4000:]
        return result


@define_tool(
    description=(
        "Run the APIM/Foundry gateway pytest suite from inside the Foundry "
        "project's network fabric and return a structured summary. Use this "
        "any time the user asks to test, verify, smoke, or validate a gateway "
        "or model routing deployment."
    )
)
async def run_tests(params: RunTestsParams) -> dict:
    """Execute the pytest gateway suite as a subprocess and return junit-parsed JSON."""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _run_pytest_sync, params)


# ── System prompt ─────────────────────────────────────────────────────────────

SYSTEM_PROMPT = f"""\
You are the Gateway Test Agent — an on-Azure diagnostic assistant for
Azure API Management (APIM), Azure AI Foundry accounts, and the model-routing
gateway policies that connect them.

You are deployed as a hosted agent inside the Foundry project
`{FOUNDRY_PROJECT_ENDPOINT}` and share its network fabric, so private-endpoint
APIMs and Foundry accounts that laptop callers can't reach are addressable
from here.

Tools available to you:

  * bash / shell  — built-in Copilot tool. Use for `curl -v`, `nslookup`,
    `dig`, `openssl s_client`, `cat`, `ls`, etc. Great for probing HTTP
    endpoints, DNS records, and TLS certs.
  * File read / write / edit — built-in Copilot tools for inspecting the
    pytest suite bundled with the agent.
  * run_tests(tests, env, markers, verbose) — executes the pytest gateway
    suite (test_gateway.py) as a subprocess and returns a junit-parsed
    summary. Prefer this over hand-crafted curl for anything the suite
    already covers (model routing, contract auth, unknown-model rejection,
    embeddings, realtime, deployments listing, ...).

Guidelines:

  * When the user asks to "test a deployment" with no other detail, call
    `run_tests` with `tests=['test_gateway.py']` and echo the summary.
  * When the user names a specific concern (auth, PE reachability, DNS,
    TLS), pick the right tool: shell for one-off probes, run_tests for the
    canned assertions.
  * If a test fails with a network error (403 from APIM, TLS handshake,
    NXDOMAIN), fall back to shell to characterize it: nslookup the host,
    curl -v the URL, and report both the pytest failure and the raw probe.
  * Keep output tight. Report the summary object first, then the failing
    tests, then any follow-up you performed.
"""


# ── Responses handler ────────────────────────────────────────────────────────

app = ResponsesAgentServerHost()


@app.response_handler
async def handle_create(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal: asyncio.Event,
):
    """Drive a Copilot SDK session and stream its output over Responses SSE."""
    stream = ResponseEventStream(response_id=context.response_id, request=request)
    yield stream.emit_created()
    yield stream.emit_in_progress()

    user_input = (await context.get_input_text()) or ""

    message_item = stream.add_output_item_message()
    yield message_item.emit_added()
    text_content = message_item.add_text_content()
    yield text_content.emit_added()

    # Resolve the model provider config for this request. When
    # APIM_CONNECTION_NAME is set we look up the named APIM connection on the
    # Foundry project; otherwise we BYOK straight to the Foundry account.
    provider = await _resolve_provider()


    # Queue of (kind, payload) events emitted by the Copilot session on its
    # own event loop; the handler drains them into the SSE stream.
    delta_queue: asyncio.Queue[tuple[str, Any]] = asyncio.Queue()

    def _on_event(event: Any) -> None:
        etype = event.type
        if etype == SessionEventType.ASSISTANT_MESSAGE_DELTA:
            delta_queue.put_nowait(("delta", event.data.delta_content))
        elif etype == SessionEventType.ASSISTANT_MESSAGE:
            delta_queue.put_nowait(("full", event.data.content))
        elif etype == SessionEventType.SESSION_ERROR:
            logger.warning("copilot session error: %s", getattr(event.data, "message", event.data))
            delta_queue.put_nowait(("error", getattr(event.data, "message", str(event.data))))
        elif etype == SessionEventType.SESSION_IDLE:
            delta_queue.put_nowait(("done", None))

    client = CopilotClient()
    await client.start()
    try:
        session = await client.create_session(
            on_permission_request=PermissionHandler.approve_all,
            model=AZURE_AI_MODEL_DEPLOYMENT_NAME,
            streaming=True,
            tools=[run_tests],
            provider=provider,
            system_message={"mode": "append", "content": SYSTEM_PROMPT},
        )
        session.on(_on_event)

        async def _send_wrapper():
            try:
                await session.send(user_input)
            except Exception:
                logger.exception("session.send raised")
                delta_queue.put_nowait(("error", "session.send raised"))

        send_task = asyncio.create_task(_send_wrapper())

        emitted_any_delta = False
        full_text = ""
        errored: str | None = None
        while True:
            if cancellation_signal.is_set():
                yield stream.emit_incomplete("cancelled")
                return
            try:
                kind, payload = await asyncio.wait_for(delta_queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            if kind == "delta":
                emitted_any_delta = True
                full_text += payload
                yield text_content.emit_delta(payload)
            elif kind == "full" and not emitted_any_delta:
                full_text = payload
                yield text_content.emit_delta(payload)
            elif kind == "error":
                errored = payload
                break
            elif kind == "done":
                break

        await send_task
        if errored and not full_text:
            full_text = f"[agent error: {errored}]"
            yield text_content.emit_delta(full_text)
        try:
            await session.disconnect()
        except Exception:  # pragma: no cover — best effort
            logger.exception("session disconnect failed")
    finally:
        try:
            await client.stop()
        except Exception:  # pragma: no cover
            logger.exception("client stop failed")

    yield text_content.emit_text_done(full_text)
    yield text_content.emit_done()
    yield message_item.emit_done()
    yield stream.emit_completed()


if __name__ == "__main__":
    logger.info(
        "Starting Gateway Test Agent (Responses) — model=%s, foundry=%s",
        AZURE_AI_MODEL_DEPLOYMENT_NAME,
        FOUNDRY_MODEL_URL,
    )
    app.run()

