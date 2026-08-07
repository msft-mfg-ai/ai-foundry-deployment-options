"""Live smoke tests for both hosted agents and both MCP prompt agents."""

from __future__ import annotations

import asyncio
import os
import socket
import subprocess
from collections.abc import AsyncIterator

import aiohttp
import dns.resolver
import pytest
import pytest_asyncio
from aiohttp.abc import AbstractResolver
from azure.identity.aio import AzureCliCredential


def _azd_value(name: str) -> str:
    command = ["azd", "env", "get-value", name]
    environment = os.environ.get("AZD_ENV_NAME")
    if environment:
        command.extend(["-e", environment])
    result = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


class PublicDnsFallbackResolver(AbstractResolver):
    """Use public DNS when the host resolver stops at a Private Link CNAME."""

    async def resolve(
        self,
        host: str,
        port: int = 0,
        family: socket.AddressFamily = socket.AF_INET,
    ) -> list[dict]:
        try:
            addresses = await asyncio.get_running_loop().getaddrinfo(
                host,
                port,
                family=family,
                type=socket.SOCK_STREAM,
            )
            ips = sorted({address[4][0] for address in addresses})
        except socket.gaierror:
            resolver = dns.resolver.Resolver(configure=False)
            resolver.nameservers = ["1.1.1.1", "8.8.8.8"]
            answers = await asyncio.to_thread(resolver.resolve, host, "A")
            ips = [answer.address for answer in answers]

        return [
            {
                "hostname": host,
                "host": ip,
                "port": port,
                "family": socket.AF_INET,
                "proto": socket.IPPROTO_TCP,
                "flags": socket.AI_NUMERICHOST,
            }
            for ip in ips
        ]

    async def close(self) -> None:
        return None


@pytest_asyncio.fixture
async def access_token() -> AsyncIterator[str]:
    credential = AzureCliCredential()
    try:
        token = await credential.get_token("https://ai.azure.com/.default")
        yield token.token
    finally:
        await credential.close()


@pytest_asyncio.fixture
async def session(access_token: str) -> AsyncIterator[aiohttp.ClientSession]:
    connector = aiohttp.TCPConnector(resolver=PublicDnsFallbackResolver())
    timeout = aiohttp.ClientTimeout(total=180)
    headers = {"Authorization": f"Bearer {access_token}"}
    async with aiohttp.ClientSession(
        connector=connector,
        timeout=timeout,
        headers=headers,
    ) as client:
        yield client


async def _post_response(
    session: aiohttp.ClientSession,
    endpoint: str,
    payload: dict,
) -> tuple[int, dict]:
    async with session.post(endpoint, json=payload) as response:
        return response.status, await response.json(content_type=None)


async def _run_response(
    session: aiohttp.ClientSession,
    endpoint: str,
    payload: dict,
) -> tuple[int, dict]:
    status, response = await _post_response(session, endpoint, payload)
    for _ in range(3):
        approvals = [
            {
                "type": "mcp_approval_response",
                "approve": True,
                "approval_request_id": item["id"],
            }
            for item in response.get("output", [])
            if item.get("type") == "mcp_approval_request" and item.get("id")
        ]
        if not approvals:
            return status, response
        status, response = await _post_response(
            session,
            endpoint,
            {
                "previous_response_id": response["id"],
                "input": approvals,
            },
        )
    return status, response


def _output_text(response: dict) -> str:
    if response.get("output_text"):
        return str(response["output_text"]).strip()
    texts = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text" and content.get("text"):
                texts.append(content["text"])
    return " ".join(texts).strip()


@pytest.mark.parametrize(
    ("endpoint_key", "agent_name"),
    [
        ("AGENT_HOSTED_AGENT_NO_CAP_RESPONSES_ENDPOINT", "hosted-agent-no-cap"),
        ("AGENT_HOSTED_AGENT_WITH_CAP_RESPONSES_ENDPOINT", "hosted-agent-with-cap"),
    ],
)
async def test_hosted_agent_uses_mcp(
    session: aiohttp.ClientSession,
    endpoint_key: str,
    agent_name: str,
) -> None:
    endpoint = _azd_value(endpoint_key)
    status, response = await _run_response(
        session,
        endpoint,
        {
            "input": (
                "Use the add tool from the sample-mcp server to calculate "
                "2 plus 3. Return only the result."
            )
        },
    )
    output = _output_text(response)
    print(f"{agent_name}: HTTP {status}: {output}")
    assert status == 200, response
    assert response.get("status") == "completed", response
    assert output == "5"


async def test_prompt_agent_with_cap_uses_mcp(
    session: aiohttp.ClientSession,
) -> None:
    endpoint = f"{_azd_value('FOUNDRY_PROJECT_ENDPOINT_WITH_CAP')}/openai/v1/responses"
    status, response = await _run_response(
        session,
        endpoint,
        {
            "input": (
                "Use the add tool from the sample-mcp server to calculate "
                "2 plus 3. Return only the result."
            ),
            "agent_reference": {
                "name": "prompt-mcp-with-cap",
                "type": "agent_reference",
            },
        },
    )
    output = _output_text(response)
    print(f"prompt-mcp-with-cap: HTTP {status}: {output}")
    assert status == 200, response
    assert response.get("status") == "completed", response
    assert output == "5"


async def test_prompt_agent_without_cap_requires_capability_host(
    session: aiohttp.ClientSession,
) -> None:
    endpoint = f"{_azd_value('FOUNDRY_PROJECT_ENDPOINT_NO_CAP')}/openai/v1/responses"
    status, response = await _post_response(
        session,
        endpoint,
        {
            "input": "Reply with exactly OK.",
            "agent_reference": {
                "name": "prompt-mcp-no-cap",
                "type": "agent_reference",
            },
        },
    )
    error = response.get("error", {})
    print(f"prompt-mcp-no-cap: HTTP {status}: {error}")
    if status == 424 and error.get("code") == "tool_server_error":
        pytest.fail(
            "prompt-mcp-no-cap cannot run because its project has no project-level "
            "capability host (HTTP 424 tool_server_error)."
        )
    pytest.fail(
        "prompt-mcp-no-cap unexpectedly returned a different result; this project "
        f"has no project-level capability host. HTTP {status}: {response}"
    )
