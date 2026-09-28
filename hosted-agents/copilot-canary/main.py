"""Copilot SDK → APIM direct canary (hosted agent).

Verifies the `copilot-sdk-via-apim-direct` topology from *inside* the Foundry
VNet, where APIM's private endpoint is reachable (public network access is
disabled). Also exercises the Copilot SDK's built-in shell + files tools by
auto-approving every permission request, per
https://devblogs.microsoft.com/agent-framework/build-ai-agents-with-github-copilot-sdk-and-microsoft-agent-framework/

Uses the Microsoft Agent Framework wrapper (`GitHubCopilotAgent`), which:
  - accepts `on_permission_request` correctly (as a default_option, not a
    top-level create_session kwarg — the older hand-rolled CopilotClient wiring
    silently no-ops), and
  - returns the assistant's actual text from `await agent.run(prompt)` (the
    hand-rolled `session.send()` returned a session/message id, which was the
    root cause of the "UUID instead of assistant text" bug seen earlier).

Auth is the hosted agent's managed-identity token, scoped to
`https://cognitiveservices.azure.com/.default` — the same audience APIM's
inbound policy accepts.

Telemetry: no client-side instrumentation required. The Invocations protocol
runtime auto-emits OTel traces to the App Insights resource that Foundry
links to the project. See
https://learn.microsoft.com/azure/foundry/agents/how-to/configure-hosted-agent-telemetry
The `env` sub-probe surfaces whether `APPLICATIONINSIGHTS_CONNECTION_STRING`
was injected — useful when traces don't show up.

Env vars:
  APIM_BASE_URL   e.g. https://apim-...azure-api.net (bicep output)
  CHAT_MODEL      APIM deployment name, e.g. gpt-4o-mini
"""
import base64
import json
import os
import tempfile
import time
import uuid

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.identity import DefaultAzureCredential
from starlette.requests import Request
from starlette.responses import JSONResponse

_APIM_BASE = os.environ["APIM_BASE_URL"].rstrip("/")
# Model used for the BYOK/APIM canary. Defaults to gpt-5.1 (the real Foundry
# deployment) because the Copilot SDK's built-in `apply_patch` tool declares
# itself as an OpenAI custom-grammar tool — a GPT-5-only Responses API feature.
# `CHAT_MODEL` (e.g. gpt-4o-mini) is kept as the fallback for the older
# wire_api="completions" path where custom-grammar tools are silently omitted.
_MODEL = os.environ.get("COPILOT_CANARY_MODEL") or os.environ["CHAT_MODEL"]
_cred = DefaultAzureCredential()


def _auto_approve(request, _ctx=None):
    """Approve every shell/files/URL permission request the SDK raises so we
    can prove those tools reach APIM through the Foundry VNet path.

    Must return a `PermissionDecision*` DATACLASS instance from
    `copilot.generated.rpc` — a plain dict `{"kind": "approved"}` is
    interpreted as denial and the tool silently reports
    "Permission denied to execute the command." Verified locally 2026-07-29.
    In production you'd gate this on `request.commands` / `request.path`."""
    from copilot.generated.rpc import PermissionDecisionApproveOnce  # noqa: WPS433
    return PermissionDecisionApproveOnce()


def _provider() -> dict:
    """Build the BYOK provider config for CopilotClient — points the SDK at
    our APIM AI Gateway instead of GitHub's default model backend."""
    token = _cred.get_token("https://cognitiveservices.azure.com/.default").token
    return {
        "type": "openai",
        # `responses` is the SDK's native path and the ONLY one that
        # exercises the Copilot CLI's full tool schema — including
        # `apply_patch` which is declared as an OpenAI custom-grammar tool
        # (`{"type": "custom", "format": {"type": "grammar", "syntax":
        # "lark", ...}}`). That's a GPT-5-only feature, which is why
        # COPILOT_CANARY_MODEL defaults to gpt-5.1. On chat/completions
        # (`wire_api: "completions"`) that tool is silently dropped, so
        # the canary would give a false-positive greenlight to a broken
        # BYOK path in reality.
        "wire_api": "responses",
        # APIM's OpenAI-compatible base is /inference/openai/v1/ (see
        # rg-testing-byom/apim-ai-3swd46vd3j22a APIs). The stale
        # apim-ai-mtsz6xvxogaq4 name in older envs no longer resolves.
        "base_url": f"{_APIM_BASE}/inference/openai/v1/",
        "wire_model": _MODEL,
        "bearer_token": token,
    }


async def _run_agent(prompt: str, instructions: str) -> str:
    """One-shot: create an Agent Framework GitHubCopilotAgent, run the prompt,
    return the assistant's actual text.

    Correct API shape (verified against agent-framework-github-copilot 1.0.0
    by running locally and inspecting the wrapper source + BYOK handling):
      - `instructions` is a top-level constructor arg → becomes the agent's
        system message. Passing it inside `default_options` raises
        `TypeError: create_session() got an unexpected keyword argument
        'instructions'` because default_options is forwarded verbatim to
        `CopilotClient.create_session()`.
      - `default_options` may carry only real `create_session` params:
        `provider`, `on_permission_request`, `system_message`,
        `available_tools`, `model`, etc.
      - **BYOK requires BOTH `provider` AND `model`**. Without `model` the
        CLI falls back to the empty CAPI model list and fails with
        "No model available. Check policy enablement under GitHub
        Settings > Copilot" — even when `provider` is fully set. The
        `model` value should match `provider.wire_model`."""
    from agent_framework.github import GitHubCopilotAgent  # noqa: WPS433

    async with GitHubCopilotAgent(
        instructions=instructions,
        default_options={
            "on_permission_request": _auto_approve,
            "provider": _provider(),
            # REQUIRED alongside `provider`: without a `model`, the CLI falls
            # back to the empty CAPI model list and fails with
            # "No model available. Check policy enablement under GitHub
            # Settings > Copilot" — even though the BYOK provider is set. The
            # value matches provider.wire_model.
            "model": _MODEL,
            # GPT-5-class reasoning models are slower per turn, and the files
            # probe issues 2 tool calls (write + read). The SDK's default
            # 60s session.idle timeout trips on files with gpt-5.1.
            "timeout": 180.0,
        },
    ) as agent:
        result = await agent.run(prompt)
        # AgentRunResponse -> str via its text/output_text attr, or __str__
        return getattr(result, "text", None) or getattr(result, "output_text", None) or str(result)


async def _probe_chat() -> dict:
    started = time.monotonic()
    try:
        text = await _run_agent(
            "What is 7 plus 5? Reply with just the number.",
            instructions="You are a calculator. Reply with just the number, nothing else.",
        )
        ok = "12" in text
        return {"name": "chat", "ok": ok, "output_text": text.strip(),
                "latency_ms": int((time.monotonic() - started) * 1000)}
    except Exception as e:  # noqa: BLE001
        return {"name": "chat", "ok": False, "error": f"{type(e).__name__}: {e}",
                "latency_ms": int((time.monotonic() - started) * 1000)}


async def _probe_bash() -> dict:
    """Prove the SDK's built-in shell tool reaches APIM through this route."""
    started = time.monotonic()
    sentinel = f"apim-canary-{uuid.uuid4().hex[:8]}"
    try:
        text = await _run_agent(
            f"Use the shell tool to run `echo {sentinel}` and reply with ONLY that command's stdout.",
            instructions="You have shell access. Use the shell tool to fulfil the user's request; return only the exact command output.",
        )
        return {"name": "bash", "ok": sentinel in text, "output_text": text.strip(),
                "expected_substring": sentinel,
                "latency_ms": int((time.monotonic() - started) * 1000)}
    except Exception as e:  # noqa: BLE001
        return {"name": "bash", "ok": False, "error": f"{type(e).__name__}: {e}",
                "expected_substring": sentinel,
                "latency_ms": int((time.monotonic() - started) * 1000)}


async def _probe_files() -> dict:
    """Prove the SDK's file read/write tools reach APIM through this route."""
    started = time.monotonic()
    workdir = tempfile.mkdtemp(prefix="copilot-canary-")
    path = os.path.join(workdir, "hello.txt")
    payload = f"hello-{uuid.uuid4().hex[:8]}"
    result: dict = {"name": "files", "expected_substring": payload, "file_path": path}
    try:
        text = await _run_agent(
            (
                f"Using the file tools, write the exact text {payload!r} to the file at path {path!r}, "
                f"then read it back and reply with ONLY the file contents."
            ),
            instructions="You have file read/write tools. Use them; do not fabricate results.",
        )
        result["output_text"] = text.strip()
        result["ok"] = payload in text
    except Exception as e:  # noqa: BLE001
        result["error"] = f"{type(e).__name__}: {e}"
        result["ok"] = False

    try:
        result["file_on_disk"] = open(path, encoding="utf-8").read()
    except Exception as e:  # noqa: BLE001
        result["file_on_disk_error"] = f"{type(e).__name__}: {e}"
    result["latency_ms"] = int((time.monotonic() - started) * 1000)
    return result


async def _run_task(
    task: str,
    workdir: str | None = None,
    *,
    session_id: str | None = None,
) -> dict:
    """Run a free-form task with shell + files tools enabled.

    Body shape: `{"task": "<free-form English task>", "workdir": "<optional>"}`.
    The agent is auto-approved for every permission request and gets a
    generic executor system prompt. Returns the assistant's final text
    plus a directory listing of workdir so the caller can see any files
    the agent produced.

    Files created here live under `$HOME/tasks/<uuid>/` so they show up in
    the hosted-agent portal Files tab (the session-persistent filesystem);
    files under `/tmp` are not exposed."""
    started = time.monotonic()
    if not workdir:
        base = os.path.join(os.environ.get("HOME", "/tmp"), "tasks")
        os.makedirs(base, exist_ok=True)
        workdir = tempfile.mkdtemp(prefix="task-", dir=base)
    else:
        os.makedirs(workdir, exist_ok=True)

    instructions = (
        "You are an autonomous task executor with access to shell, file "
        "read/write, and URL fetch tools. Complete the user's task using "
        f"those tools. Your working directory is {workdir!r} — write any "
        "files there.\n\n"
        "Available skills in this container:\n"
        "- PowerPoint generation: `python-pptx` is installed. A branded 16:9 "
        "  starter template lives at `/app/assets/template.pptx` with these "
        "  named layouts (access via `next(l for l in prs.slide_layouts if "
        "  l.name == '<name>')`): 'Cover', 'Section Divider', 'Timeline + "
        "  Callouts', 'Six Card Grid', 'Comparison Rows', 'Four Step "
        "  Process', 'Numbered Action List', 'Six Card Grid - Alt', 'Four "
        "  Card Grid - Alt', 'Link Appendix', 'Source List'. The template "
        "  also contains 17 filled example slides — inspect them for shape "
        "  placement, then either duplicate a slide's XML "
        "  (`copy.deepcopy(slide.element)`) or add a fresh slide from the "
        "  named layout. Prefer `Presentation('/app/assets/template.pptx')` "
        "  over `Presentation()` so decks share look-and-feel.\n"
        "- Rendering / conversion: LibreOffice `soffice` is installed. "
        "  Convert with `soffice --headless --convert-to pdf deck.pptx` "
        "  (or `--convert-to png` for a preview).\n"
        "- Image manipulation: `pillow` is installed.\n\n"
        "When done, reply with a short summary of what you did and the "
        "paths of any files you created."
    )
    try:
        text = await _run_agent(task, instructions=instructions)
        ok = True
        error: str | None = None
    except Exception as e:  # noqa: BLE001
        text = ""
        ok = False
        error = f"{type(e).__name__}: {e}"

    # Snapshot workdir contents so the caller sees what the agent produced.
    # Files under $HOME are exposed by the Foundry Session Files API
    # (docs: https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-sessions#session-file-operations),
    # so for each we also emit a ready-to-run `az rest` download command and
    # the raw HTTPS URL. Binary content is inlined as base64 (<=10MB) as a
    # fallback when the caller can't authenticate to the data-plane endpoint.
    _MAX_INLINE = 10 * 1024 * 1024
    home = os.environ.get("HOME", "/")
    agent_name = os.environ.get("FOUNDRY_AGENT_NAME", "")
    project_endpoint = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "").rstrip("/")
    api_version = "v1"

    def _download_bits(portal_path: str) -> dict:
        if not (session_id and agent_name and project_endpoint and portal_path):
            return {}
        # Session Files API path is relative to $HOME (no leading slash).
        rel_from_home = portal_path.lstrip("/")
        qs = f"api-version={api_version}&path={rel_from_home}"
        url = (
            f"{project_endpoint}/agents/{agent_name}/endpoint/sessions/"
            f"{session_id}/files/content?{qs}"
        )
        out_name = os.path.basename(rel_from_home) or "downloaded"
        az_cmd = (
            f'az rest --method GET --resource "https://ai.azure.com" '
            f'--url "{url}" --output-file "{out_name}"'
        )
        return {"download_url": url, "az_rest": az_cmd}

    files: list[dict] = []
    try:
        for root, _dirs, filenames in os.walk(workdir):
            for name in filenames:
                p = os.path.join(root, name)
                try:
                    size = os.path.getsize(p)
                except OSError:
                    size = -1
                rel = os.path.relpath(p, workdir)
                # portal_path: path under $HOME with a leading "/" — matches
                # the shape the portal Files tab uses in its download URL.
                if p.startswith(home.rstrip("/") + "/"):
                    portal_path = "/" + os.path.relpath(p, home)
                else:
                    portal_path = None
                entry: dict = {"path": rel, "size": size, "portal_path": portal_path}
                if portal_path:
                    entry.update(_download_bits(portal_path))
                if 0 < size <= 4096:
                    try:
                        entry["preview"] = open(p, encoding="utf-8", errors="replace").read()
                    except OSError:
                        pass
                if 0 < size <= _MAX_INLINE:
                    try:
                        with open(p, "rb") as fh:
                            entry["content_b64"] = base64.b64encode(fh.read()).decode("ascii")
                    except OSError:
                        pass
                elif size > _MAX_INLINE:
                    entry["truncated"] = True
                files.append(entry)
    except OSError:
        pass

    result: dict = {
        "name": "task",
        "ok": ok,
        "task": task,
        "workdir": workdir,
        "session_id": session_id,
        "output_text": text.strip() if text else "",
        "files": files,
        "latency_ms": int((time.monotonic() - started) * 1000),
    }
    if error:
        result["error"] = error
    return result


_CODE_VERSION = "2026-08-01-real-template"


def _probe_env() -> dict:
    """Report which observability + BYOK env vars Foundry actually injected,
    plus a code-version marker so we can tell if a redeploy actually shipped.

    Doesn't fail the overall canary — this is diagnostic. If
    APPLICATIONINSIGHTS_CONNECTION_STRING is missing, project monitoring
    isn't wired to inject into this agent version (env vars are immutable
    per version — you have to redeploy after enabling monitoring).
    """
    keys = [
        "APPLICATIONINSIGHTS_CONNECTION_STRING",
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "APIM_BASE_URL",
        "CHAT_MODEL",
        "FOUNDRY_PROJECT_ENDPOINT",
    ]
    seen = {k: bool(os.environ.get(k)) for k in keys}
    return {
        "name": "env",
        "ok": True,
        "code_version": _CODE_VERSION,
        "apim_base_url": os.environ.get("APIM_BASE_URL", ""),
        "seen": seen,
    }


app = InvocationAgentServerHost()


@app.invoke_handler
async def handle_invoke(request: Request) -> JSONResponse:
    """Invocation body dispatches on shape:

    - `{"task": "<free-form English>"}` (optional `"workdir": "/tmp/foo"`) —
      run the Copilot agent against the task with shell + files + URL
      tools auto-approved, returning the assistant's final text and a
      snapshot of any files created in the workdir.
    - `{"probe": "chat"|"bash"|"files"|"env"|"all"}` — run one or all of
      the fixed BYOK canary probes.
    - Empty body → equivalent to `{"probe": "all"}`.
    """
    which = "all"
    task: str | None = None
    workdir: str | None = None
    body = await request.body()
    if body:
        try:
            payload = json.loads(body)
            if isinstance(payload, dict):
                if payload.get("task"):
                    task = str(payload["task"])
                    workdir = payload.get("workdir")
                elif payload.get("probe"):
                    which = str(payload["probe"])
        except json.JSONDecodeError:
            pass

    # Free-form task mode.
    if task is not None:
        session_id = getattr(request.state, "session_id", None)
        result = await _run_task(task, workdir=workdir, session_id=session_id)
        return JSONResponse({"ok": result["ok"], "tests": [_probe_env(), result]})

    probes_async = {"chat": _probe_chat, "bash": _probe_bash, "files": _probe_files}
    tests: list[dict] = []
    if which == "env":
        tests.append(_probe_env())
    elif which == "all":
        tests.append(_probe_env())
        for _name, fn in probes_async.items():
            tests.append(await fn())
    else:
        tests.append(await probes_async[which]())

    # env is diagnostic; don't let it dominate the overall ok bit
    ok = all(t.get("ok") for t in tests if t.get("name") != "env")
    return JSONResponse({"ok": ok, "tests": tests})


if __name__ == "__main__":
    app.run()
