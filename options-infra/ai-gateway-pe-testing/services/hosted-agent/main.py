"""BYOM canary hosted agent (Invocations protocol, agentserver 2.0.0).

Runs a small BYOM probe matrix from *inside* the Foundry-hosted container:

  - Responses API through the static OpenAI APIM gateway (BYOM_MODEL).
  - Responses API through the static Anthropic APIM gateway (BYOM_MODEL_ANTHROPIC), if set.

Each probe is reported as {name, ok, error, latency_ms} in the invocation
response. The BYOM matrix in msft-mfg-ai/foundry-byom-feature-support polls
this endpoint and asserts every probe returned ok=True.

BYOM convention:
  The `model` argument passed to `aoai.responses.create` is the single string
  "{connection}/{model}" (e.g. "apim-...-openai-s-.../gpt-4o-mini"), which tells
  Foundry to forward the call to the APIM connection instead of a local
  deployment. That composed string is provided by the platform via BYOM_MODEL.

Env vars:
  - FOUNDRY_PROJECT_ENDPOINT  platform-injected on every hosted agent runtime.
  - BYOM_MODEL                declared in azure.yaml (services.byom-canary.environmentVariables).
  - BYOM_MODEL_ANTHROPIC      optional, same source.
"""
import json
import os
import time

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from starlette.requests import Request
from starlette.responses import JSONResponse

_PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
_BYOM_MODEL = os.environ["BYOM_MODEL"]                                    # "<static-conn>/<model>"
_BYOM_MODEL_DYNAMIC = os.environ.get("BYOM_MODEL_DYNAMIC") or None        # "<dynamic-conn>/<model>", optional
_BYOM_MODEL_ANTHROPIC = os.environ.get("BYOM_MODEL_ANTHROPIC") or None    # "<anthropic-conn>/<model>", optional

_project = AIProjectClient(endpoint=_PROJECT_ENDPOINT, credential=DefaultAzureCredential())
_aoai = _project.get_openai_client()


def _probe(name: str, model: str, prompt: str):
    """Run one BYOM Responses probe and return a JSON-serialisable result."""
    started = time.monotonic()
    try:
        resp = _aoai.responses.create(model=model, input=prompt)
        return {
            "name": name,
            "model": model,
            "ok": True,
            "output_text": (resp.output_text or "").strip(),
            "latency_ms": int((time.monotonic() - started) * 1000),
        }
    except Exception as e:  # noqa: BLE001 - canary swallows and reports
        return {
            "name": name,
            "model": model,
            "ok": False,
            "error": f"{type(e).__name__}: {e}",
            "latency_ms": int((time.monotonic() - started) * 1000),
        }


app = InvocationAgentServerHost()


@app.invoke_handler
async def handle_invoke(request: Request) -> JSONResponse:
    body = await request.body()
    payload = json.loads(body) if body else {}
    # New Invocations schema uses "message"; keep "prompt" as a legacy fallback.
    prompt = payload.get("message") or payload.get("prompt") or "Reply with the single word: ok."

    tests = [_probe("responses-openai-static", _BYOM_MODEL, prompt)]
    if _BYOM_MODEL_DYNAMIC:
        tests.append(_probe("responses-openai-dynamic", _BYOM_MODEL_DYNAMIC, prompt))
    if _BYOM_MODEL_ANTHROPIC:
        tests.append(_probe("responses-anthropic-static", _BYOM_MODEL_ANTHROPIC, prompt))

    return JSONResponse({
        "ok": all(t["ok"] for t in tests),
        "tests": tests,
    })


if __name__ == "__main__":
    app.run()
