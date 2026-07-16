"""BYOM canary hosted agent (Invocations protocol).

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
"""
import json
import os
import time

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.ai.agentserver.invocations import InvocationAgentServerHost
from starlette.requests import Request
from starlette.responses import JSONResponse

# Platform-injected. Present on every Foundry hosted agent runtime.
_PROJECT_ENDPOINT = os.environ["AZURE_AI_PROJECT_ENDPOINT"]

# Declared in agent.yaml, populated by the extension from azd env at deploy time.
_BYOM_MODEL = os.environ["BYOM_MODEL"]                                    # "<conn>/<model>"
_BYOM_MODEL_ANTHROPIC = os.environ.get("BYOM_MODEL_ANTHROPIC") or None    # optional

_project = AIProjectClient(endpoint=_PROJECT_ENDPOINT, credential=DefaultAzureCredential())
_aoai = _project.get_openai_client()


def _probe(name: str, model: str, prompt: str = "Reply with the single word: ok."):
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
async def handle(request: Request) -> JSONResponse:
    body = await request.body()
    payload = json.loads(body) if body else {}
    prompt = payload.get("prompt", "Reply with the single word: ok.")

    tests = [_probe("responses-openai-static", _BYOM_MODEL, prompt)]
    if _BYOM_MODEL_ANTHROPIC:
        tests.append(_probe("responses-anthropic-static", _BYOM_MODEL_ANTHROPIC, prompt))

    return JSONResponse({
        "ok": all(t["ok"] for t in tests),
        "tests": tests,
    })


if __name__ == "__main__":
    app.run()
