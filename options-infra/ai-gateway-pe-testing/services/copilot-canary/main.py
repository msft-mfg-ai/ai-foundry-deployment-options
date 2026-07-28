"""Copilot SDK → APIM direct canary (hosted agent).

Verifies the `copilot-sdk-via-apim-direct` topology from *inside* the Foundry
VNet, where APIM's private endpoint is reachable (public network access is
disabled). Also exercises the Copilot SDK's built-in shell + files tools by
auto-approving permission requests, per
https://devblogs.microsoft.com/agent-framework/build-ai-agents-with-github-copilot-sdk-and-microsoft-agent-framework/

Auth is the hosted agent's managed-identity token, scoped to
`https://cognitiveservices.azure.com/.default` — the same audience APIM's
inbound policy accepts.

Env vars:
  APIM_BASE_URL   e.g. https://apim-...azure-api.net (bicep output)
  CHAT_MODEL      APIM deployment name, e.g. gpt-4o-mini
"""
import json
import os
import tempfile
import time
import uuid

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.identity import DefaultAzureCredential
from copilot.client import CopilotClient
from starlette.requests import Request
from starlette.responses import JSONResponse

_APIM_BASE = os.environ["APIM_BASE_URL"].rstrip("/")
_MODEL = os.environ["CHAT_MODEL"]
_cred = DefaultAzureCredential()


def _auto_approve(request, _ctx):
    """Approve every shell/files/URL permission request the SDK raises so we
    can prove those tools reach APIM through the Foundry VNet path.
    In production you'd gate this on `request['kind']`."""
    try:
        from copilot.types import PermissionRequestResult
        return PermissionRequestResult(kind="approved")
    except Exception:
        return {"kind": "approved"}


async def _session(prompt: str) -> dict:
    started = time.monotonic()
    client = CopilotClient()
    try:
        token = _cred.get_token("https://cognitiveservices.azure.com/.default").token
        await client.start()
        session = await client.create_session(
            provider={
                "type": "openai",
                "wire_api": "responses",
                "base_url": f"{_APIM_BASE}/openai/v1/",
                "wire_model": _MODEL,
                "bearer_token": token,
            },
            on_permission_request=_auto_approve,
        )
        text = await session.send(prompt)
        await session.disconnect()
        return {"ok": True, "output_text": (text or "").strip(),
                "latency_ms": int((time.monotonic() - started) * 1000)}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {e}",
                "latency_ms": int((time.monotonic() - started) * 1000)}
    finally:
        try:
            await client.stop()
        except Exception:
            pass


async def _probe_chat() -> dict:
    return await _session("Reply with the single word: ok.")


async def _probe_bash() -> dict:
    """Prove the SDK's built-in shell tool reaches APIM through this route."""
    sentinel = f"apim-canary-{uuid.uuid4().hex[:8]}"
    r = await _session(
        f"Use the shell tool to run `echo {sentinel}` and return only its stdout."
    )
    r["expected_substring"] = sentinel
    r["ok"] = r.get("ok", False) and sentinel in (r.get("output_text") or "")
    return r


async def _probe_files() -> dict:
    """Prove the SDK's file read/write tools reach APIM through this route."""
    workdir = tempfile.mkdtemp(prefix="copilot-canary-")
    path = os.path.join(workdir, "hello.txt")
    payload = f"hello-{uuid.uuid4().hex[:8]}"
    r = await _session(
        f"Using the file tools, write the exact text {payload!r} to {path!r}, "
        f"then read it back and reply with only its contents."
    )
    r["expected_substring"] = payload
    r["file_path"] = path
    try:
        r["file_on_disk"] = open(path, encoding="utf-8").read()
    except Exception as e:  # noqa: BLE001
        r["file_on_disk_error"] = f"{type(e).__name__}: {e}"
    r["ok"] = r.get("ok", False) and payload in (r.get("output_text") or "")
    return r


app = InvocationAgentServerHost()


@app.invoke_handler
async def handle_invoke(request: Request) -> JSONResponse:
    """Invocation body may specify {"probe": "chat"|"bash"|"files"|"all"}.
    Default runs all three so a single hosted-agent invoke covers the matrix.
    """
    which = "all"
    body = await request.body()
    if body:
        try:
            payload = json.loads(body)
            if isinstance(payload, dict) and payload.get("probe"):
                which = str(payload["probe"])
        except json.JSONDecodeError:
            pass

    probes = {"chat": _probe_chat, "bash": _probe_bash, "files": _probe_files}
    to_run = list(probes.items()) if which == "all" else [(which, probes[which])]
    tests = []
    for name, fn in to_run:
        result = await fn()
        tests.append({"name": name, **result})
    return JSONResponse({"ok": all(t.get("ok") for t in tests), "tests": tests})


if __name__ == "__main__":
    app.run()
