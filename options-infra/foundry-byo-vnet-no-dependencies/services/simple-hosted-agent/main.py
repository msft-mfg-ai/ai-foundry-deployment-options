import http.client
import ipaddress
import os
import secrets
import socket
import struct
from pathlib import Path
from urllib.parse import urlparse

from agent_framework import Agent, SkillsProvider
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential


AZURE_PLATFORM_DNS_IP = "168.63.129.16"
NETWORK_TIMEOUT_SECONDS = 5


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


def validate_network_injection() -> dict[str, object]:
    """Test DNS and HTTPS connectivity from this hosted agent to its own Foundry project.

    Use this tool when asked whether VNet injection, Azure DNS, name resolution,
    or connectivity to this agent's Foundry project is working.
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
            "This validates the runtime DNS and HTTPS path from inside the hosted agent. "
            "It does not independently read the ARM networkInjections configuration."
        ),
    }


def main() -> None:
    model_name = os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"]
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=model_name,
        credential=DefaultAzureCredential(),
    )
    agent = Agent(
        client=client,
        instructions=(
            "You are a friendly assistant. Keep answers brief. Use the network "
            "injection diagnostics skill for Foundry networking questions."
        ),
        tools=[validate_network_injection],
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
