#!/usr/bin/env python3
"""Discover, configure, and remove Technitium DNS for an existing Foundry VNet."""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import uuid


class CustomDnsError(RuntimeError):
    """Expected operator, Azure, or Technitium error."""


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise CustomDnsError(f"Command failed ({' '.join(args[:5])}): {detail}")
    return result


def require_tools(*names: str) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise CustomDnsError(f"Missing required command(s): {', '.join(missing)}")


def az_json(args: list[str]) -> Any:
    return json.loads(run(["az", *args, "-o", "json"]).stdout)


def azd_get(key: str, default: str = "") -> str:
    if value := os.environ.get(key):
        return value
    result = run(["azd", "env", "get-value", key], check=False)
    return result.stdout.strip() if result.returncode == 0 else default


def azd_set(key: str, value: str) -> None:
    run(["azd", "env", "set", key, value])


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{label}{suffix}: ").strip()
    return value or default


def env_or_prompt(key: str, label: str, default: str = "") -> str:
    if value := azd_get(key):
        print(f"Reusing {label}: {value}")
        return value
    return prompt(label, default)


def choose(label: str, values: list[dict[str, Any]]) -> dict[str, Any]:
    if not values:
        raise CustomDnsError(f"No choices available for {label}.")
    print(f"\n{label}:")
    for index, value in enumerate(values, start=1):
        prefixes = ", ".join(value.get("addressPrefixes") or [])
        print(
            f"  {index}. {value['name']} | {value['resourceGroup']} | "
            f"{value['location']} | {prefixes}"
        )
    while True:
        raw = prompt("Select number")
        if raw.isdigit() and 1 <= int(raw) <= len(values):
            return values[int(raw) - 1]
        print("Enter one of the listed numbers.")


def parse_network(value: str, label: str) -> ipaddress.IPv4Network:
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise CustomDnsError(f"{label} must be a canonical IPv4 CIDR: {exc}") from exc
    if not isinstance(network, ipaddress.IPv4Network):
        raise CustomDnsError(f"{label} must be IPv4.")
    return network


def find_free_subnet(
    vnet_prefixes: list[ipaddress.IPv4Network],
    used: list[ipaddress.IPv4Network],
    prefix_length: int = 24,
) -> ipaddress.IPv4Network:
    for vnet_prefix in vnet_prefixes:
        if vnet_prefix.prefixlen > prefix_length:
            continue
        for candidate in vnet_prefix.subnets(new_prefix=prefix_length):
            if not any(candidate.overlaps(existing) for existing in used):
                return candidate
    raise CustomDnsError(
        f"No free /{prefix_length} subnet was found in the selected VNet."
    )


def normalize_record(record: dict[str, Any]) -> dict[str, Any]:
    required = {"zone", "name", "type", "value"}
    missing = sorted(required - record.keys())
    if missing:
        raise CustomDnsError(f"DNS record is missing: {', '.join(missing)}")

    zone = str(record["zone"]).strip().rstrip(".").lower()
    name = str(record["name"]).strip().rstrip(".").lower()
    record_type = str(record["type"]).strip().upper()
    value = str(record["value"]).strip().rstrip(".")
    ttl = int(record.get("ttl", 300))

    if not zone or not name or not value:
        raise CustomDnsError("DNS record zone, name, and value cannot be empty.")
    if record_type not in {"A", "CNAME"}:
        raise CustomDnsError("Only A and CNAME records are supported.")
    if ttl < 1:
        raise CustomDnsError("DNS record TTL must be positive.")
    if name == "@":
        name = zone
    elif "." not in name:
        name = f"{name}.{zone}"
    if name != zone and not name.endswith(f".{zone}"):
        raise CustomDnsError(f"Record {name} is outside zone {zone}.")
    if record_type == "A":
        try:
            ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError as exc:
            raise CustomDnsError(f"A record value is not an IPv4 address: {value}") from exc
    elif "." not in value:
        value = f"{value}.{zone}"

    return {
        "zone": zone,
        "name": name,
        "type": record_type,
        "value": value,
        "ttl": ttl,
    }


def parse_records(raw: str) -> list[dict[str, Any]]:
    try:
        records = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        raise CustomDnsError(f"CUSTOM_DNS_RECORDS_JSON is invalid JSON: {exc}") from exc
    if not isinstance(records, list):
        raise CustomDnsError("CUSTOM_DNS_RECORDS_JSON must be a JSON array.")
    if not all(isinstance(record, dict) for record in records):
        raise CustomDnsError("Each DNS record must be a JSON object.")
    return [normalize_record(record) for record in records]


def discover_linked_private_dns(
    subscription_id: str, vnet_id: str
) -> tuple[list[str], list[dict[str, Any]]]:
    escaped_vnet_id = vnet_id.replace("'", "''")
    result = az_json(
        [
            "graph",
            "query",
            "-q",
            (
                "resources "
                "| where type =~ 'microsoft.network/privatednszones/virtualnetworklinks' "
                f"| where properties.virtualNetwork.id =~ '{escaped_vnet_id}' "
                "| extend zoneName=tostring(split(id, '/')[8]) "
                "| project zoneName, resourceGroup"
            ),
            "--subscriptions",
            subscription_id,
        ]
    )
    linked_zones = sorted(
        {
            (item["resourceGroup"], item["zoneName"])
            for item in result.get("data", [])
        }
    )
    records: list[dict[str, Any]] = []
    for resource_group, zone in linked_zones:
        record_sets = az_json(
            [
                "network",
                "private-dns",
                "record-set",
                "list",
                "--subscription",
                subscription_id,
                "--resource-group",
                resource_group,
                "--zone-name",
                zone,
            ]
        )
        for record_set in record_sets:
            record_type = record_set["type"].rsplit("/", 1)[-1].upper()
            if record_type in {"SOA", "NS"}:
                continue
            records.extend(flatten_azure_record_set(zone, record_set))
    return [zone for _, zone in linked_zones], records


def flatten_azure_record_set(
    zone: str, record_set: dict[str, Any]
) -> list[dict[str, Any]]:
    record_type = record_set["type"].rsplit("/", 1)[-1].upper()
    name = str(record_set.get("fqdn") or "").rstrip(".")
    ttl = int(record_set.get("ttl", 300))
    parameters: list[dict[str, Any]]
    if record_type == "A":
        parameters = [
            {"ipAddress": item["ipv4Address"]}
            for item in record_set.get("aRecords") or []
        ]
    elif record_type == "AAAA":
        parameters = [
            {"ipAddress": item["ipv6Address"]}
            for item in record_set.get("aaaaRecords") or []
        ]
    elif record_type == "CNAME":
        cname = (record_set.get("cnameRecord") or {}).get("cname")
        parameters = [{"cname": cname.rstrip(".")}] if cname else []
    elif record_type == "PTR":
        parameters = [
            {"ptrName": item["ptrdname"].rstrip(".")}
            for item in record_set.get("ptrRecords") or []
        ]
    elif record_type == "MX":
        parameters = [
            {
                "exchange": item["exchange"].rstrip("."),
                "preference": item["preference"],
            }
            for item in record_set.get("mxRecords") or []
        ]
    elif record_type == "SRV":
        parameters = [
            {
                "priority": item["priority"],
                "weight": item["weight"],
                "port": item["port"],
                "target": item["target"].rstrip("."),
            }
            for item in record_set.get("srvRecords") or []
        ]
    elif record_type == "TXT":
        parameters = [
            {
                "characterStringsBase64": ",".join(
                    base64.b64encode(value.encode()).decode()
                    for value in item.get("value") or []
                )
            }
            for item in record_set.get("txtRecords") or []
        ]
    else:
        raise CustomDnsError(
            f"Linked private DNS record type {record_type} is not supported."
        )
    return [
        {
            "zone": zone,
            "name": name,
            "type": record_type,
            "ttl": ttl,
            "overwrite": index == 0,
            "parameters": item,
        }
        for index, item in enumerate(parameters)
    ]


def discover(dry_run: bool) -> None:
    require_tools("az", "azd")
    account = az_json(["account", "show"])
    subscription_id = azd_get("CUSTOM_DNS_TARGET_SUBSCRIPTION_ID", account["id"])
    ownership_id = azd_get("CUSTOM_DNS_OWNERSHIP_ID") or str(uuid.uuid4())

    existing_name = azd_get("CUSTOM_DNS_VNET_NAME")
    existing_rg = azd_get("CUSTOM_DNS_VNET_RESOURCE_GROUP")
    if existing_name and existing_rg:
        selected = {"name": existing_name, "resourceGroup": existing_rg}
    else:
        selected = choose(
            "Existing VNets",
            az_json(
                [
                    "network",
                    "vnet",
                    "list",
                    "--subscription",
                    subscription_id,
                    "--query",
                    "[].{name:name,resourceGroup:resourceGroup,location:location,addressPrefixes:addressSpace.addressPrefixes}",
                ]
            ),
        )

    vnet = az_json(
        [
            "network",
            "vnet",
            "show",
            "--subscription",
            subscription_id,
            "--resource-group",
            selected["resourceGroup"],
            "--name",
            selected["name"],
        ]
    )
    mode = env_or_prompt(
        "CUSTOM_DNS_DEPLOYMENT_MODE",
        "DNS deployment mode (Public or Private)",
        "Public",
    ).title()
    if mode not in {"Public", "Private"}:
        raise CustomDnsError("Deployment mode must be Public or Private.")

    default_rg = re.sub(r"[^A-Za-z0-9_.()-]", "-", f"rg-{selected['name']}-custom-dns")[:90]
    dns_rg = env_or_prompt(
        "CUSTOM_DNS_RESOURCE_GROUP", "Custom DNS resource group", default_rg
    )
    existing_dns_rg = run(
        [
            "az",
            "group",
            "show",
            "--subscription",
            subscription_id,
            "--name",
            dns_rg,
            "-o",
            "json",
        ],
        check=False,
    )
    if existing_dns_rg.returncode == 0:
        tags = json.loads(existing_dns_rg.stdout).get("tags", {})
        if tags.get("custom-dns-owner") != ownership_id:
            raise CustomDnsError(
                f"Resource group {dns_rg} already exists and is not owned by this azd environment."
            )

    subnet_name = azd_get("CUSTOM_DNS_SUBNET_NAME") or "custom-dns-aci-subnet"
    subnet_cidr = ""
    if mode == "Private":
        prefixes = [
            parse_network(prefix, "VNet prefix")
            for prefix in vnet["addressSpace"]["addressPrefixes"]
        ]
        subnets = vnet.get("subnets", [])
        existing_subnet = next(
            (item for item in subnets if item["name"].lower() == subnet_name.lower()),
            None,
        )
        if existing_subnet:
            delegations = {
                item.get("serviceName")
                for item in existing_subnet.get("delegations", [])
            }
            if "Microsoft.ContainerInstance/containerGroups" not in delegations:
                raise CustomDnsError(
                    f"Existing subnet {subnet_name} is not delegated to ACI."
                )
            subnet_cidr = (
                existing_subnet.get("addressPrefixes")
                or [existing_subnet.get("addressPrefix")]
            )[0]
        else:
            used = [
                parse_network(prefix, f"Subnet {item['name']} prefix")
                for item in subnets
                for prefix in (
                    item.get("addressPrefixes")
                    or ([item["addressPrefix"]] if item.get("addressPrefix") else [])
                )
            ]
            subnet_cidr = str(find_free_subnet(prefixes, used))
        subnet_cidr = env_or_prompt(
            "CUSTOM_DNS_SUBNET_CIDR", "ACI DNS subnet CIDR", subnet_cidr
        )
        parse_network(subnet_cidr, "ACI DNS subnet CIDR")

    manual_records = parse_records(azd_get("CUSTOM_DNS_RECORDS_JSON", "[]"))
    linked_zones, discovered_records = discover_linked_private_dns(
        subscription_id, vnet["id"]
    )
    values = {
        "CUSTOM_DNS_TARGET_SUBSCRIPTION_ID": subscription_id,
        "CUSTOM_DNS_VNET_RESOURCE_GROUP": selected["resourceGroup"],
        "CUSTOM_DNS_VNET_NAME": selected["name"],
        "CUSTOM_DNS_VNET_ID": vnet["id"],
        "CUSTOM_DNS_LOCATION": vnet["location"],
        "CUSTOM_DNS_RESOURCE_GROUP": dns_rg,
        "CUSTOM_DNS_DEPLOYMENT_MODE": mode,
        "CUSTOM_DNS_SUBNET_NAME": subnet_name,
        "CUSTOM_DNS_SUBNET_CIDR": subnet_cidr,
        "CUSTOM_DNS_ADMIN_PASSWORD": (
            azd_get("CUSTOM_DNS_ADMIN_PASSWORD") or secrets.token_urlsafe(32)
        ),
        "CUSTOM_DNS_IMAGE": azd_get(
            "CUSTOM_DNS_IMAGE", "docker.io/technitium/dns-server:latest"
        ),
        "CUSTOM_DNS_OWNERSHIP_ID": ownership_id,
        "CUSTOM_DNS_RECORDS_JSON": json.dumps(manual_records, separators=(",", ":")),
        "CUSTOM_DNS_LINKED_ZONES_JSON": json.dumps(
            linked_zones, separators=(",", ":")
        ),
        "CUSTOM_DNS_DISCOVERED_RECORDS_JSON": json.dumps(
            discovered_records, separators=(",", ":")
        ),
        "CUSTOM_DNS_PREVIOUS_VNET_SERVERS_JSON": json.dumps(
            vnet.get("dhcpOptions", {}).get("dnsServers") or [],
            separators=(",", ":"),
        ),
        "CUSTOM_DNS_APPLY_TO_VNET": azd_get("CUSTOM_DNS_APPLY_TO_VNET", "false"),
    }

    print("\nResolved custom DNS configuration:")
    for key in (
        "CUSTOM_DNS_VNET_NAME",
        "CUSTOM_DNS_RESOURCE_GROUP",
        "CUSTOM_DNS_DEPLOYMENT_MODE",
        "CUSTOM_DNS_SUBNET_CIDR",
        "CUSTOM_DNS_RECORDS_JSON",
        "CUSTOM_DNS_LINKED_ZONES_JSON",
        "CUSTOM_DNS_DISCOVERED_RECORDS_JSON",
        "CUSTOM_DNS_APPLY_TO_VNET",
    ):
        print(f"  {key}={values[key]}")
    if dry_run:
        return
    for key, value in values.items():
        azd_set(key, value)


class TechnitiumClient:
    def __init__(self, base_url: str, password: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.password = password
        self.token = ""
        self.ssl_context = ssl._create_unverified_context()

    def request(
        self, path: str, parameters: dict[str, Any], *, authenticated: bool = True
    ) -> dict[str, Any]:
        data = urlencode(parameters).encode()
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.token}"
        request = Request(f"{self.base_url}{path}", data=data, headers=headers)
        try:
            with urlopen(request, timeout=15, context=self.ssl_context) as response:
                payload = json.loads(response.read())
        except (HTTPError, URLError, TimeoutError) as exc:
            raise CustomDnsError(f"Technitium request failed for {path}: {exc}") from exc
        if payload.get("status") != "ok":
            raise CustomDnsError(
                payload.get("errorMessage") or f"Technitium returned {payload.get('status')}"
            )
        return payload

    def login(self) -> None:
        payload = self.request(
            "/api/user/login",
            {"user": "admin", "pass": self.password},
            authenticated=False,
        )
        self.token = payload["token"]

    def ensure_zone(self, zone: str) -> None:
        try:
            self.request("/api/zones/create", {"zone": zone, "type": "Primary"})
        except CustomDnsError as exc:
            if "already exists" not in str(exc).lower():
                raise

    def set_dns_settings(self, deployment_mode: str) -> None:
        self.request(
            "/api/settings/set",
            {
                "recursion": (
                    "AllowOnlyForPrivateNetworks"
                    if deployment_mode == "Private"
                    else "Deny"
                ),
                "forwarders": "168.63.129.16",
                "forwarderProtocol": "Udp",
            },
        )

    def set_record(self, record: dict[str, Any]) -> None:
        parameters: dict[str, Any] = {
            "zone": record["zone"],
            "domain": record["name"],
            "type": record["type"],
            "ttl": record["ttl"],
            "overwrite": str(record.get("overwrite", True)).lower(),
        }
        if "parameters" in record:
            parameters.update(record["parameters"])
        elif record["type"] == "A":
            parameters["ipAddress"] = record["value"]
        else:
            parameters["cname"] = record["value"]
        self.request("/api/zones/records/add", parameters)


def update_vnet_dns(servers: list[str]) -> None:
    subscription_id = required_env("CUSTOM_DNS_TARGET_SUBSCRIPTION_ID")
    vnet_id = required_env("CUSTOM_DNS_VNET_ID")
    command = [
        "az",
        "network",
        "vnet",
        "update",
        "--ids",
        vnet_id,
        "--subscription",
        subscription_id,
    ]
    if servers:
        command.extend(["--dns-servers", *servers])
    else:
        command.extend(["--remove", "dhcpOptions.dnsServers"])
    run(command)


def validate_udp_dns(server_ip: str, domain: str) -> None:
    transaction_id = secrets.randbelow(65536)
    header = struct.pack("!HHHHHH", transaction_id, 0x0100, 1, 0, 0, 0)
    question = b"".join(
        bytes([len(label)]) + label.encode("ascii") for label in domain.split(".")
    ) + b"\x00" + struct.pack("!HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns_socket:
        dns_socket.settimeout(10)
        dns_socket.sendto(header + question, (server_ip, 53))
        response, _ = dns_socket.recvfrom(4096)
    if len(response) < 12:
        raise CustomDnsError("Technitium returned a malformed DNS response.")
    response_id, flags, _, answer_count, _, _ = struct.unpack("!HHHHHH", response[:12])
    if response_id != transaction_id:
        raise CustomDnsError("Technitium returned a mismatched DNS response.")
    if flags & 0xF:
        raise CustomDnsError(f"Technitium DNS query failed with RCODE {flags & 0xF}.")
    if answer_count < 1:
        raise CustomDnsError(f"Technitium returned no answer for {domain}.")


def required_env(key: str) -> str:
    value = azd_get(key)
    if not value:
        raise CustomDnsError(f"Required azd environment value {key} is missing.")
    return value


def configure() -> None:
    require_tools("azd")
    base_url = required_env("CUSTOM_DNS_API_URL")
    client = TechnitiumClient(base_url, required_env("CUSTOM_DNS_ADMIN_PASSWORD"))
    for attempt in range(1, 31):
        try:
            client.login()
            break
        except CustomDnsError:
            if attempt == 30:
                raise
            time.sleep(10)

    client.set_dns_settings(required_env("CUSTOM_DNS_DEPLOYMENT_MODE"))

    manual_records = parse_records(azd_get("CUSTOM_DNS_RECORDS_JSON", "[]"))
    records = [
        *json.loads(azd_get("CUSTOM_DNS_DISCOVERED_RECORDS_JSON", "[]")),
        *manual_records,
    ]
    zones = [
        *json.loads(azd_get("CUSTOM_DNS_LINKED_ZONES_JSON", "[]")),
        *(record["zone"] for record in manual_records),
    ]
    for zone in dict.fromkeys(zones):
        client.ensure_zone(zone)
    for record in records:
        client.set_record(record)
        print(
            f"Configured {record['type']} {record['name']} -> {record['value']}"
            if "value" in record
            else f"Configured {record['type']} {record['name']}"
        )

    validation_record = next(
        (record for record in records if record["type"] == "A"), None
    )
    if validation_record:
        server_ip = required_env("CUSTOM_DNS_SERVER_IP")
        validate_udp_dns(server_ip, validation_record["name"])
        print(f"Validated UDP DNS resolution through {server_ip}.")

    if azd_get("CUSTOM_DNS_APPLY_TO_VNET", "false").lower() == "true":
        require_tools("az")
        update_vnet_dns([required_env("CUSTOM_DNS_SERVER_IP")])
        azd_set("CUSTOM_DNS_VNET_DNS_APPLIED", "true")
        print("Applied the Technitium server IP to the existing VNet DNS settings.")

    print(f"Technitium is ready at {base_url}")


def cleanup() -> None:
    require_tools("az", "azd")
    if azd_get("CUSTOM_DNS_VNET_DNS_APPLIED", "false").lower() == "true":
        previous = json.loads(azd_get("CUSTOM_DNS_PREVIOUS_VNET_SERVERS_JSON", "[]"))
        update_vnet_dns(previous)

    if azd_get("CUSTOM_DNS_DEPLOYMENT_MODE") == "Private":
        result = run(
            [
                "az",
                "network",
                "vnet",
                "subnet",
                "delete",
                "--subscription",
                required_env("CUSTOM_DNS_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                required_env("CUSTOM_DNS_VNET_RESOURCE_GROUP"),
                "--vnet-name",
                required_env("CUSTOM_DNS_VNET_NAME"),
                "--name",
                required_env("CUSTOM_DNS_SUBNET_NAME"),
            ],
            check=False,
        )
        if result.returncode != 0 and "not found" not in (
            result.stderr or result.stdout
        ).lower():
            raise CustomDnsError(result.stderr or result.stdout)

    dns_rg = run(
        [
            "az",
            "group",
            "show",
            "--subscription",
            required_env("CUSTOM_DNS_TARGET_SUBSCRIPTION_ID"),
            "--name",
            required_env("CUSTOM_DNS_RESOURCE_GROUP"),
            "-o",
            "json",
        ],
        check=False,
    )
    if dns_rg.returncode == 0:
        tags = json.loads(dns_rg.stdout).get("tags", {})
        if tags.get("custom-dns-owner") != required_env("CUSTOM_DNS_OWNERSHIP_ID"):
            raise CustomDnsError("Refusing to delete a resource group owned elsewhere.")
        run(
            [
                "az",
                "group",
                "delete",
                "--subscription",
                required_env("CUSTOM_DNS_TARGET_SUBSCRIPTION_ID"),
                "--name",
                required_env("CUSTOM_DNS_RESOURCE_GROUP"),
                "--yes",
                "--no-wait",
            ]
        )
    print("Sample-owned custom DNS resources were removed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    discover_parser = subparsers.add_parser("discover")
    discover_parser.add_argument("--dry-run", action="store_true")
    subparsers.add_parser("configure")
    subparsers.add_parser("cleanup")
    args = parser.parse_args()
    try:
        if args.command == "discover":
            discover(args.dry_run)
        elif args.command == "configure":
            configure()
        else:
            cleanup()
    except CustomDnsError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
