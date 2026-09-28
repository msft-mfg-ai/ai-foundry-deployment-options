import http.client
import ipaddress
import json
import logging
import os
import secrets
import socket
import struct
from pathlib import Path
from urllib.parse import urlparse

from agent_framework import Agent, MCPStreamableHTTPTool, SkillsProvider
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential


AZURE_PLATFORM_DNS_IP = "168.63.129.16"
NETWORK_TIMEOUT_SECONDS = 5
logger = logging.getLogger(__name__)


def _system_dns_lookup(hostname: str) -> dict[str, object]:
    try:
        records = socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        return {"ok": False, "addresses": [], "error": str(error)}

    addresses = sorted({record[4][0] for record in records})
    return {
        "ok": bool(addresses),
        "addresses": addresses,
        "private_addresses": [
            address for address in addresses if ipaddress.ip_address(address).is_private
        ],
    }


def _azure_dns_probe(hostname: str) -> dict[str, object]:
    transaction_id = secrets.randbits(16)
    labels = hostname.rstrip(".").split(".")
    question = b"".join(
        bytes([len(label_bytes)]) + label_bytes
        for label in labels
        if (label_bytes := label.encode("idna"))
    )
    packet = (
        struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
        + question
        + b"\x00"
        + struct.pack("!HH", 1, 1)
    )

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns_socket:
            dns_socket.settimeout(NETWORK_TIMEOUT_SECONDS)
            dns_socket.sendto(packet, (AZURE_PLATFORM_DNS_IP, 53))
            response, responder = dns_socket.recvfrom(4096)
    except (OSError, TimeoutError) as error:
        return {
            "ok": False,
            "resolver": AZURE_PLATFORM_DNS_IP,
            "error": str(error),
        }

    if len(response) < 12:
        return {
            "ok": False,
            "resolver": responder[0],
            "error": "Azure DNS returned a truncated response.",
        }

    response_id, flags, _, answer_count, _, _ = struct.unpack("!HHHHHH", response[:12])
    response_code = flags & 0x000F
    valid_response = response_id == transaction_id and bool(flags & 0x8000)
    error = None
    if not valid_response:
        error = "Azure DNS returned an invalid response."
    elif response_code != 0:
        error = f"Azure DNS returned response code {response_code}."
    elif answer_count == 0:
        error = "Azure DNS returned no answers."

    return {
        "ok": valid_response and response_code == 0 and answer_count > 0,
        "resolver": responder[0],
        "response_code": response_code,
        "answer_count": answer_count,
        "error": error,
    }


def _https_probe(hostname: str, path: str) -> dict[str, object]:
    connection = http.client.HTTPSConnection(hostname, timeout=NETWORK_TIMEOUT_SECONDS)
    try:
        connection.request("GET", path or "/")
        response = connection.getresponse()
        return {
            "ok": True,
            "status": response.status,
            "reason": response.reason,
        }
    except (OSError, TimeoutError, http.client.HTTPException) as error:
        return {"ok": False, "error": str(error)}
    finally:
        connection.close()


def _arm_get(resource_id: str, credential: DefaultAzureCredential) -> dict[str, object]:
    token = credential.get_token("https://management.azure.com/.default").token
    connection = http.client.HTTPSConnection(
        "management.azure.com", timeout=NETWORK_TIMEOUT_SECONDS
    )
    try:
        connection.request(
            "GET",
            f"{resource_id}/capabilityHosts?api-version=2025-06-01",
            headers={"Authorization": f"Bearer {token}"},
        )
        response = connection.getresponse()
        body = response.read().decode("utf-8")
        payload = json.loads(body) if body else {}
        result: dict[str, object] = {
            "ok": response.status == 200,
            "status": response.status,
            "reason": response.reason,
        }
        if response.status == 200:
            result["capability_hosts"] = [
                {
                    "name": item.get("name"),
                    "properties": item.get("properties", {}),
                }
                for item in payload.get("value", [])
            ]
        else:
            result["error"] = payload.get("error", payload)
            if response.status == 403:
                result["remediation"] = (
                    "Assign the hosted agent instance identity the Reader role "
                    "on the resource group containing the Foundry account."
                )
        return result
    except (OSError, TimeoutError, http.client.HTTPException, json.JSONDecodeError) as error:
        return {
            "ok": False,
            "error": str(error),
            "error_type": type(error).__name__,
        }
    finally:
        connection.close()


async def validate_network_injection() -> dict[str, object]:
    """Test Foundry and configured MCP connectivity from this hosted agent.

    Use this tool when asked whether VNet injection, Azure DNS, name resolution,
    MCP tool discovery, or private connectivity is working.
    """
    project_endpoint = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
    parsed_endpoint = urlparse(project_endpoint)
    if parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname:
        return {
            "ok": False,
            "project_endpoint": project_endpoint,
            "error": "FOUNDRY_PROJECT_ENDPOINT is not a valid HTTPS URL.",
        }

    hostname = parsed_endpoint.hostname
    system_dns = _system_dns_lookup(hostname)
    azure_dns = _azure_dns_probe(hostname)
    https = _https_probe(hostname, parsed_endpoint.path)
    checks = {
        "system_dns": system_dns,
        "azure_platform_dns": azure_dns,
        "foundry_https": https,
    }

    project_resource_id = os.environ.get("AZURE_AI_PROJECT_ID")
    if project_resource_id and "/projects/" in project_resource_id:
        account_resource_id = project_resource_id.rsplit("/projects/", 1)[0]
        credential = DefaultAzureCredential()
        try:
            checks["foundry_account_capability_hosts"] = _arm_get(
                account_resource_id, credential
            )
            checks["foundry_project_capability_hosts"] = _arm_get(
                project_resource_id, credential
            )
        finally:
            credential.close()
    else:
        checks["capability_hosts"] = {
            "ok": False,
            "error": "AZURE_AI_PROJECT_ID is missing or invalid.",
        }

    mcp_server_url = os.environ.get("MCP_SERVER_URL")
    if mcp_server_url:
        mcp_server_name = os.environ.get("MCP_SERVER_NAME", "mcp-server")
        parsed_mcp_url = urlparse(mcp_server_url)
        if parsed_mcp_url.scheme != "https" or not parsed_mcp_url.hostname:
            checks["mcp_server"] = {
                "ok": False,
                "server_name": mcp_server_name,
                "server_url": mcp_server_url,
                "error": "MCP_SERVER_URL is not a valid HTTPS URL.",
            }
        else:
            mcp_dns = _system_dns_lookup(parsed_mcp_url.hostname)
            try:
                async with MCPStreamableHTTPTool(
                    name=f"{mcp_server_name}-diagnostic",
                    url=mcp_server_url,
                    load_prompts=False,
                    request_timeout=NETWORK_TIMEOUT_SECONDS,
                ) as mcp_probe:
                    available_tools = [
                        {
                            "name": function.name,
                            "description": function.description,
                        }
                        for function in mcp_probe.functions
                    ]
                checks["mcp_server"] = {
                    "ok": True,
                    "server_name": mcp_server_name,
                    "server_url": mcp_server_url,
                    "hostname": parsed_mcp_url.hostname,
                    "addresses": mcp_dns.get("addresses", []),
                    "private_addresses": mcp_dns.get("private_addresses", []),
                    "tools": available_tools,
                    "tools_count": len(available_tools),
                }
            except Exception as error:
                logger.exception("Failed to list tools from MCP server %s", mcp_server_url)
                checks["mcp_server"] = {
                    "ok": False,
                    "server_name": mcp_server_name,
                    "server_url": mcp_server_url,
                    "hostname": parsed_mcp_url.hostname,
                    "addresses": mcp_dns.get("addresses", []),
                    "private_addresses": mcp_dns.get("private_addresses", []),
                    "error": str(error),
                    "error_type": type(error).__name__,
                }

    passed = all(bool(check.get("ok")) for check in checks.values())

    return {
        "ok": passed,
        "verdict": (
            "The hosted runtime can resolve and reach its Foundry project through Azure DNS."
            if passed
            else "One or more runtime network checks failed; inspect the individual checks."
        ),
        "project_endpoint": project_endpoint,
        "hostname": hostname,
        "checks": checks,
        "scope_note": (
            "This validates runtime DNS and HTTPS connectivity to Foundry and performs "
            "MCP tools/list from inside the hosted agent when MCP_SERVER_URL is configured. "
            "It also reads account and project capability hosts through Azure Resource "
            "Manager when AZURE_AI_PROJECT_ID is configured."
        ),
    }


def main() -> None:
    model_name = os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"]
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=model_name,
        credential=DefaultAzureCredential(),
    )
    tools = [validate_network_injection]
    mcp_server_url = os.environ.get("MCP_SERVER_URL")
    mcp_server_name = os.environ.get("MCP_SERVER_NAME", "mcp-server")
    if mcp_server_url:
        tools.append(
            MCPStreamableHTTPTool(
                name=mcp_server_name,
                url=mcp_server_url,
                description=f"Tools provided by the {mcp_server_name} MCP server.",
                approval_mode="never_require",
            )
        )
    else:
        logger.warning(
            "MCP_SERVER_URL is not set. The %s MCP tool will not be registered.",
            mcp_server_name,
        )

    agent = Agent(
        client=client,
        instructions=(
            f"You are a friendly assistant. Keep answers brief. Use the "
            f"{mcp_server_name} MCP tools when relevant and the network injection "
            "diagnostics skill for Foundry networking questions."
        ),
        tools=tools,
        context_providers=[
            SkillsProvider.from_paths(
                skill_paths=str(Path(__file__).parent / "skills")
            )
        ],
        default_options={"store": False},
    )
    ResponsesHostServer(agent).run()


if __name__ == "__main__":
    main()
