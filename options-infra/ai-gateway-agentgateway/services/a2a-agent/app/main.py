from __future__ import annotations

import os
import uuid
from typing import Any

import uvicorn
from azure.monitor.opentelemetry import configure_azure_monitor
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

_ID_NAMESPACE = uuid.UUID("74f7363d-c57a-48f5-91ec-0df35adb64ef")


def _configure_telemetry() -> None:
    connection_string = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if connection_string:
        configure_azure_monitor(
            connection_string=connection_string,
            logger_name="agentgateway-a2a-agent",
        )


def _agent_url(request: Request) -> str:
    configured_url = os.getenv("A2A_PUBLIC_URL", "").strip()
    return configured_url.rstrip("/") if configured_url else str(request.base_url).rstrip("/")


def _agent_card(request: Request) -> dict[str, Any]:
    return {
        "protocolVersion": "0.3.0",
        "name": "Agentgateway Sample Agent",
        "description": "Returns a deterministic acknowledgement for text messages.",
        "url": _agent_url(request),
        "preferredTransport": "JSONRPC",
        "version": "1.0.0",
        "capabilities": {
            "streaming": False,
            "pushNotifications": False,
            "stateTransitionHistory": False,
        },
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [
            {
                "id": "acknowledge",
                "name": "Acknowledge text",
                "description": "Returns a deterministic acknowledgement of supplied text.",
                "tags": ["sample", "deterministic"],
                "examples": ["hello agent"],
            }
        ],
    }


def _text_from_params(params: Any) -> str | None:
    if not isinstance(params, dict):
        return None
    message = params.get("message")
    if not isinstance(message, dict):
        return None
    parts = message.get("parts")
    if not isinstance(parts, list):
        return None

    text_parts = [
        part.get("text", "")
        for part in parts
        if isinstance(part, dict)
        and part.get("kind", part.get("type")) == "text"
        and isinstance(part.get("text"), str)
    ]
    text = " ".join(part.strip() for part in text_parts if part.strip())
    return text or None


def _jsonrpc_error(request_id: Any, code: int, message: str) -> JSONResponse:
    return JSONResponse(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }
    )


async def health(_: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


async def agent_card(request: Request) -> JSONResponse:
    return JSONResponse(_agent_card(request))


async def jsonrpc(request: Request) -> JSONResponse:
    try:
        payload = await request.json()
    except ValueError:
        return _jsonrpc_error(None, -32700, "Parse error")

    if not isinstance(payload, dict) or payload.get("jsonrpc") != "2.0":
        return _jsonrpc_error(
            payload.get("id") if isinstance(payload, dict) else None,
            -32600,
            "Invalid Request",
        )

    request_id = payload.get("id")
    if payload.get("method") != "message/send":
        return _jsonrpc_error(request_id, -32601, "Method not found")

    text = _text_from_params(payload.get("params"))
    if text is None:
        return _jsonrpc_error(request_id, -32602, "A text message part is required")

    params = payload["params"]
    incoming_message = params["message"]
    context_seed = str(incoming_message.get("contextId") or text)
    context_id = str(uuid.uuid5(_ID_NAMESPACE, f"context:{context_seed}"))
    message_id = str(uuid.uuid5(_ID_NAMESPACE, f"reply:{context_id}:{text}"))

    return JSONResponse(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "kind": "message",
                "messageId": message_id,
                "contextId": context_id,
                "role": "agent",
                "parts": [
                    {
                        "kind": "text",
                        "text": f"Agentgateway sample agent acknowledged: {text}",
                    }
                ],
            },
        }
    )


_configure_telemetry()

app = Starlette(
    routes=[
        Route("/health", health, methods=["GET"]),
        Route("/.well-known/agent.json", agent_card, methods=["GET"]),
        Route("/.well-known/agent-card.json", agent_card, methods=["GET"]),
        Route("/a2a/.well-known/agent.json", agent_card, methods=["GET"]),
        Route("/a2a/.well-known/agent-card.json", agent_card, methods=["GET"]),
        Route("/", jsonrpc, methods=["POST"]),
        Route("/a2a", jsonrpc, methods=["POST"]),
        Route("/a2a/", jsonrpc, methods=["POST"]),
    ]
)


def run() -> None:
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
    )


if __name__ == "__main__":
    run()

