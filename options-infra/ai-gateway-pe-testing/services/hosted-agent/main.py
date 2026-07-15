"""Tiny BYOM smoke agent (Invocations protocol).

Reads the AI Gateway connection + model from custom env vars, calls the
Foundry Responses API from inside the hosted container, and returns the
answer as JSON. Used by the byom-feature-support matrix to prove that
BYOM routing works when the caller is a hosted agent (not a script).
"""
import json
import os

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
from azure.ai.agentserver.invocations import InvocationAgentServerHost
from starlette.requests import Request
from starlette.responses import JSONResponse

_PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]  # platform-injected
_GATEWAY = os.environ["AI_GATEWAY_CONNECTION"]              # custom env var
_MODEL = os.environ["CHAT_MODEL"]                           # custom env var

_project = AIProjectClient(endpoint=_PROJECT_ENDPOINT, credential=DefaultAzureCredential())
_aoai = _project.get_openai_client()

app = InvocationAgentServerHost()


@app.invoke_handler
async def handle(request: Request) -> JSONResponse:
    body = await request.body()
    payload = json.loads(body) if body else {}
    prompt = payload.get("prompt", "Say hello.")
    resp = _aoai.responses.create(model=f"{_GATEWAY}/{_MODEL}", input=prompt)
    return JSONResponse({"output_text": resp.output_text, "model": f"{_GATEWAY}/{_MODEL}"})


if __name__ == "__main__":
    app.run()
