from __future__ import annotations

import os

from azure.monitor.opentelemetry import configure_azure_monitor
from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse


def _configure_telemetry() -> None:
    connection_string = os.getenv("APPLICATIONINSIGHTS_CONNECTION_STRING")
    if connection_string:
        configure_azure_monitor(
            connection_string=connection_string,
            logger_name="agentgateway-mcp-server",
        )


_configure_telemetry()

mcp = FastMCP(
    name="agentgateway_sample_mcp",
    instructions="Deterministic sample tools for validating agentgateway MCP proxying.",
)


@mcp.tool(
    annotations={
        "title": "Add two integers",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    }
)
def add_numbers(left: int, right: int) -> dict[str, int]:
    """Add two integers and return the operands with their sum."""
    return {"left": left, "right": right, "sum": left + right}


@mcp.tool(
    annotations={
        "title": "Get sample service status",
        "readOnlyHint": True,
        "destructiveHint": False,
        "idempotentHint": True,
        "openWorldHint": False,
    }
)
def get_service_status(service: str = "agentgateway") -> dict[str, str]:
    """Return a deterministic status for a named sample service."""
    normalized = service.strip().lower() or "agentgateway"
    return {"service": normalized, "status": "operational"}


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


@mcp.custom_route("/", methods=["GET"])
async def root(_: Request) -> JSONResponse:
    return JSONResponse(
        {
            "name": "agentgateway_sample_mcp",
            "transport": "stateless-streamable-http",
            "mcp": "/mcp/",
            "health": "/health",
        }
    )


def run() -> None:
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8000")),
        path="/mcp/",
        stateless_http=True,
    )


if __name__ == "__main__":
    run()
