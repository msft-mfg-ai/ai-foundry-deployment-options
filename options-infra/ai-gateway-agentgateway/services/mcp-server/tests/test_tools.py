from __future__ import annotations

import pytest
from fastmcp import Client

from app.main import mcp


@pytest.mark.asyncio
async def test_lists_and_calls_deterministic_tools() -> None:
    async with Client(mcp) as client:
        tools = await client.list_tools()
        assert {tool.name for tool in tools} == {"add_numbers", "get_service_status"}

        result = await client.call_tool("add_numbers", {"left": 20, "right": 22})
        assert result.data == {"left": 20, "right": 22, "sum": 42}

        status = await client.call_tool("get_service_status", {"service": " Gateway "})
        assert status.data == {"service": "gateway", "status": "operational"}

