"""FastMCP case-management server for the Foundry perf-testing scenario.

Deployed to Azure Container Apps and consumed identically by all three agent
variants (prompt, hosted, custom). In-memory dict store — no persistence — so
that MCP overhead in the perf tests reflects pure network + protocol cost, not
disk/DB latency.

Endpoints (streamable HTTP transport, mounted at /mcp):
  - tool  open_case(subject, description)   -> {case_id}
  - tool  close_case(case_id, resolution)   -> {ok, closed_at}
  - tool  fetch_case(case_id)               -> {case_id, status, subject, ...}
  - prompt case_management_workflow          -> operator playbook string

Also exposes GET /health (200 OK) for the ACA readiness probe.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from typing import Any

from azure.monitor.opentelemetry import configure_azure_monitor
from fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse

# App Insights connection string is injected by the ACA env (see main.bicep +
# aca env module). Without it, azure-monitor-opentelemetry is a no-op.
if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
        logger_name="mcp-server",
    )

_CASES: dict[str, dict[str, Any]] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


mcp: FastMCP = FastMCP(
    name="case-management",
    instructions=(
        "Fake case-management MCP server for latency benchmarking. "
        "All state is in memory and lost on restart."
    ),
)


@mcp.tool()
def open_case(subject: str, description: str) -> dict[str, Any]:
    """Open a new support case. Returns the generated `case_id`."""
    case_id = f"CS-{uuid.uuid4().hex[:8].upper()}"
    _CASES[case_id] = {
        "case_id": case_id,
        "subject": subject,
        "description": description,
        "status": "open",
        "opened_at": _now(),
        "closed_at": None,
        "resolution": None,
    }
    return {"case_id": case_id, "status": "open"}


@mcp.tool()
def close_case(case_id: str, resolution: str) -> dict[str, Any]:
    """Close an existing case with the given resolution."""
    case = _CASES.get(case_id)
    if case is None:
        return {"ok": False, "error": f"case {case_id} not found"}
    case["status"] = "closed"
    case["closed_at"] = _now()
    case["resolution"] = resolution
    return {"ok": True, "case_id": case_id, "closed_at": case["closed_at"]}


@mcp.tool()
def fetch_case(case_id: str) -> dict[str, Any]:
    """Fetch a case by ID. Returns `{error: ...}` when the case does not exist."""
    case = _CASES.get(case_id)
    if case is None:
        return {"error": f"case {case_id} not found", "case_id": case_id}
    return case


@mcp.prompt(name="case-management-workflow")
def case_management_workflow() -> str:
    """Operator playbook for the customer-support agent."""
    return (
        "You are a customer-support agent. Follow this workflow on every turn:\n"
        "\n"
        "1. Understand the customer's request.\n"
        "2. If the customer references an existing case (`CS-XXXXXXXX`), call "
        "`fetch_case` FIRST and quote its `status` before doing anything else.\n"
        "3. If the customer is reporting a new issue, call `open_case` with a "
        "one-line `subject` and a concise `description`, then confirm the new "
        "`case_id` back to them.\n"
        "4. Once an issue is resolved, call `close_case` with a brief "
        "`resolution` (one sentence).\n"
        "5. Never invent a `case_id`. If asked about a case you don't have, "
        "call `fetch_case` — do not guess.\n"
        "6. Be terse: two sentences max unless the customer asks for detail.\n"
    )


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


@mcp.custom_route("/", methods=["GET"])
async def root(_: Request) -> JSONResponse:
    return JSONResponse(
        {
            "name": "case-management",
            "mcp": "/mcp",
            "health": "/health",
            "cases_in_memory": len(_CASES),
        }
    )


if __name__ == "__main__":
    # Streamable HTTP transport, mounted at /mcp/ (FastMCP default).
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8000")),
    )
