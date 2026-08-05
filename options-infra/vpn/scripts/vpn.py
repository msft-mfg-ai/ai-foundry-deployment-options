#!/usr/bin/env python3
"""Discover, configure, validate, and remove the Foundry WireGuard VPN overlay."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any
import uuid


ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = ROOT / "results"
MANAGED_RULE_NAMES = {
    "AllowNestedInbound",
    "AllowTunnelInbound",
    "AllowNestedOutbound",
    "AllowTunnelOutbound",
}


class VpnError(RuntimeError):
    """Expected operator or environment error."""


def run(
    args: list[str],
    *,
    input_text: str | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=capture,
        check=False,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise VpnError(f"Command failed ({' '.join(args[:4])}): {detail}")
    return result


def run_allow_not_found(args: list[str]) -> None:
    result = run(args, check=False)
    if result.returncode == 0:
        return
    message = (result.stderr or result.stdout).lower()
    if "not found" in message or "resourcenotfound" in message:
        return
    raise VpnError(f"Cleanup command failed ({' '.join(args[:5])}): {message.strip()}")


def require_tools(*names: str) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        raise VpnError(f"Missing required command(s): {', '.join(missing)}")


def az_json(args: list[str]) -> Any:
    result = run(["az", *args, "-o", "json"])
    return json.loads(result.stdout)


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


def confirm(label: str, default: bool = False) -> bool:
    suffix = "Y/n" if default else "y/N"
    answer = input(f"{label} [{suffix}]: ").strip().lower()
    if not answer:
        return default
    return answer in {"y", "yes"}


def choose(label: str, values: list[dict[str, Any]], formatter) -> dict[str, Any]:
    if not values:
        raise VpnError(f"No choices available for {label}.")
    print(f"\n{label}:")
    for index, value in enumerate(values, start=1):
        print(f"  {index}. {formatter(value)}")
    while True:
        raw = prompt("Select number")
        if raw.isdigit() and 1 <= int(raw) <= len(values):
            return values[int(raw) - 1]
        print("Enter one of the listed numbers.")


def parse_resource_id(resource_id: str) -> dict[str, str]:
    parts = resource_id.strip("/").split("/")
    parsed: dict[str, str] = {}
    for index, part in enumerate(parts[:-1]):
        if part.lower() == "subscriptions":
            parsed["subscription"] = parts[index + 1]
        elif part.lower() == "resourcegroups":
            parsed["resourceGroup"] = parts[index + 1]
        elif part.lower() in {
            "virtualnetworks",
            "networksecuritygroups",
            "routetables",
            "subnets",
        }:
            parsed[part.lower()] = parts[index + 1]
    return parsed


def network(value: str, label: str) -> ipaddress.IPv4Network:
    try:
        parsed = ipaddress.ip_network(value, strict=True)
    except ValueError as exc:
        raise VpnError(f"{label} must be a canonical IPv4 CIDR: {exc}") from exc
    if not isinstance(parsed, ipaddress.IPv4Network):
        raise VpnError(f"{label} must be IPv4.")
    return parsed


def find_free_subnet(
    vnet_prefixes: list[ipaddress.IPv4Network],
    used: list[ipaddress.IPv4Network],
    prefix_length: int = 27,
) -> ipaddress.IPv4Network:
    for vnet_prefix in vnet_prefixes:
        if vnet_prefix.prefixlen > prefix_length:
            continue
        for candidate in vnet_prefix.subnets(new_prefix=prefix_length):
            if not any(candidate.overlaps(existing) for existing in used):
                return candidate
    raise VpnError(f"No free /{prefix_length} subnet was found in the selected VNet.")


def find_tunnel_network(blocked: list[ipaddress.IPv4Network]) -> ipaddress.IPv4Network:
    for index in range(256):
        candidate = ipaddress.ip_network(f"10.99.{index}.0/24")
        if not any(candidate.overlaps(item) for item in blocked):
            return candidate
    raise VpnError("No non-overlapping 10.99.x.0/24 tunnel network is available.")


def usable_ssh_key() -> tuple[Path, str]:
    ssh_dir = Path.home() / ".ssh"
    candidates = [
        ssh_dir / "id_ed25519",
        ssh_dir / "id_rsa",
        ssh_dir / "id_ecdsa",
    ]
    for private_key in candidates:
        public_key = Path(f"{private_key}.pub")
        if private_key.is_file() and public_key.is_file():
            return private_key, public_key.read_text(encoding="utf-8").strip()
    raise VpnError(
        "No matching SSH key pair was found in ~/.ssh "
        "(checked id_ed25519, id_rsa, and id_ecdsa)."
    )


def find_priority_base(rules: list[dict[str, Any]]) -> int:
    occupied: dict[str, set[int]] = {"Inbound": set(), "Outbound": set()}
    for rule in rules:
        if rule.get("name") in MANAGED_RULE_NAMES:
            continue
        direction = rule.get("direction")
        priority = rule.get("priority")
        if direction in occupied and isinstance(priority, int):
            occupied[direction].add(priority)
    for base in range(2000, 4001, 10):
        if (
            base not in occupied["Inbound"]
            and base + 10 not in occupied["Inbound"]
            and base + 20 not in occupied["Outbound"]
            and base + 30 not in occupied["Outbound"]
        ):
            return base
    raise VpnError("No collision-free NSG priority block is available between 2000 and 4030.")


def address_values(rule: dict[str, Any], singular: str, plural: str) -> list[str]:
    values = rule.get(plural) or []
    if value := rule.get(singular):
        values.append(value)
    return sorted(values)


def discover_vnet_dns(subscription_id: str, vnet_id: str) -> tuple[list[str], list[str]]:
    hostnames: set[str] = set()
    endpoints = az_json(
        ["network", "private-endpoint", "list", "--subscription", subscription_id]
    )
    subnet_prefix = f"{vnet_id.lower()}/subnets/"
    for endpoint in endpoints:
        subnet_id = endpoint.get("subnet", {}).get("id", "").lower()
        if not subnet_id.startswith(subnet_prefix):
            continue
        for dns_config in endpoint.get("customDnsConfigs") or []:
            if fqdn := dns_config.get("fqdn"):
                hostnames.add(fqdn.rstrip("."))

    linked_zones: set[str] = set()
    private_zone_hosts: set[str] = set()
    zones = az_json(
        ["network", "private-dns", "zone", "list", "--subscription", subscription_id]
    )
    for zone in zones:
        links = run(
            [
                "az",
                "network",
                "private-dns",
                "link",
                "vnet",
                "list",
                "--subscription",
                subscription_id,
                "--resource-group",
                zone["resourceGroup"],
                "--zone-name",
                zone["name"],
                "-o",
                "json",
            ],
            check=False,
        )
        if links.returncode != 0:
            continue
        if any(
            link.get("virtualNetwork", {}).get("id", "").lower() == vnet_id.lower()
            for link in json.loads(links.stdout)
        ):
            linked_zones.add(zone["name"])
            records = run(
                [
                    "az",
                    "network",
                    "private-dns",
                    "record-set",
                    "a",
                    "list",
                    "--subscription",
                    subscription_id,
                    "--resource-group",
                    zone["resourceGroup"],
                    "--zone-name",
                    zone["name"],
                    "-o",
                    "json",
                ],
                check=False,
            )
            if records.returncode == 0:
                public_suffix = zone["name"].removeprefix("privatelink.")
                for record in json.loads(records.stdout):
                    if record.get("aRecords"):
                        private_zone_hosts.add(
                            f"{record['name']}.{public_suffix}".rstrip(".")
                        )
    return sorted(hostnames | private_zone_hosts), sorted(linked_zones)


def discover_foundry_hostnames(
    subscription_id: str, resource_group: str
) -> list[str]:
    accounts = az_json(
        [
            "cognitiveservices",
            "account",
            "list",
            "--subscription",
            subscription_id,
            "--resource-group",
            resource_group,
        ]
    )
    foundry_accounts = sorted(
        accounts,
        key=lambda account: (
            account.get("kind", "").lower() != "aiservices",
            account.get("name", ""),
        ),
    )
    return [
        f"{account['name']}.services.ai.azure.com"
        for account in foundry_accounts
        if account.get("kind", "").lower() == "aiservices"
    ]


def ensure_encryption_at_host(subscription_id: str, register: bool) -> None:
    state = run(
        [
            "az",
            "feature",
            "show",
            "--subscription",
            subscription_id,
            "--namespace",
            "Microsoft.Compute",
            "--name",
            "EncryptionAtHost",
            "--query",
            "properties.state",
            "-o",
            "tsv",
        ],
        check=False,
    ).stdout.strip()
    if state == "Registered":
        return
    if not register:
        print("EncryptionAtHost is not registered; deployment would register it.")
        return
    print("Registering Microsoft.Compute/EncryptionAtHost...")
    run(
        [
            "az",
            "feature",
            "register",
            "--subscription",
            subscription_id,
            "--namespace",
            "Microsoft.Compute",
            "--name",
            "EncryptionAtHost",
            "-o",
            "none",
        ]
    )
    for _ in range(60):
        state = run(
            [
                "az",
                "feature",
                "show",
                "--subscription",
                subscription_id,
                "--namespace",
                "Microsoft.Compute",
                "--name",
                "EncryptionAtHost",
                "--query",
                "properties.state",
                "-o",
                "tsv",
            ],
            check=False,
        ).stdout.strip()
        if state == "Registered":
            run(
                [
                    "az",
                    "provider",
                    "register",
                    "--subscription",
                    subscription_id,
                    "--namespace",
                    "Microsoft.Compute",
                    "-o",
                    "none",
                ]
            )
            print("EncryptionAtHost is registered.")
            return
        time.sleep(10)
    raise VpnError(
        "Microsoft.Compute/EncryptionAtHost did not finish registering within 10 minutes."
    )


def migrate_legacy_gateway(
    subscription_id: str,
    vnet_resource_group: str,
    vpn_resource_group: str,
    private_ip: str,
    ownership_id: str,
    execute: bool,
) -> None:
    if vnet_resource_group.lower() == vpn_resource_group.lower():
        return
    nics = az_json(
        [
            "network",
            "nic",
            "list",
            "--subscription",
            subscription_id,
            "--resource-group",
            vnet_resource_group,
        ]
    )
    for nic in nics:
        if not any(
            config.get("privateIPAddress") == private_ip
            for config in nic.get("ipConfigurations", [])
        ):
            continue
        tags = nic.get("tags") or {}
        if (
            tags.get("created-by") != "options-infra-vpn"
            or tags.get("vpn-owner") != ownership_id
        ):
            raise VpnError(
                f"Private IP {private_ip} is allocated to NIC {nic['id']}, "
                "which is not owned by this azd VPN environment."
            )
        print(f"Legacy sample-owned VPN NIC found in the VNet RG: {nic['id']}")
        if not execute:
            print("Dry run: the legacy NIC and public IP would be removed.")
            continue
        if vm_id := (nic.get("virtualMachine") or {}).get("id"):
            vm = az_json(["vm", "show", "--ids", vm_id])
            vm_tags = vm.get("tags") or {}
            if (
                vm_tags.get("created-by") != "options-infra-vpn"
                or vm_tags.get("vpn-owner") != ownership_id
            ):
                raise VpnError(
                    f"Legacy NIC is attached to VM {vm_id}, which is not owned by this environment."
                )
            run(["az", "vm", "delete", "--ids", vm_id, "--yes"])
        public_ip_ids = [
            config.get("publicIPAddress", {}).get("id")
            for config in nic.get("ipConfigurations", [])
            if config.get("publicIPAddress", {}).get("id")
        ]
        run(["az", "network", "nic", "delete", "--ids", nic["id"]])
        for public_ip_id in public_ip_ids:
            run_allow_not_found(
                ["az", "network", "public-ip", "delete", "--ids", public_ip_id]
            )
        print("Removed the legacy VPN gateway allocation.")


def ssh_args(key_path: str, endpoint: str, username: str, port: str) -> list[str]:
    return [
        "ssh",
        "-i",
        str(Path(key_path).expanduser()),
        "-p",
        port,
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=15",
        "-o",
        "StrictHostKeyChecking=accept-new",
        f"{username}@{endpoint}",
    ]


def remote_run(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    if env("VPN_REMOTE_ACCESS_MODE", "ssh") == "local":
        return run(["sudo", "-n", "bash", "-s"], input_text=script, check=check)
    args = ssh_args(
        env("VPN_REMOTE_SSH_KEY_PATH"),
        env("VPN_REMOTE_SSH_ENDPOINT"),
        env("VPN_REMOTE_SSH_USERNAME"),
        env("VPN_REMOTE_SSH_PORT", "22"),
    )
    return run([*args, "sudo", "-n", "bash", "-s"], input_text=script, check=check)


def azure_run(script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    encoded_script = base64.b64encode(script.encode("utf-8")).decode("ascii")
    wrapper = (
        "set +e; "
        f"printf '%s' {shlex.quote(encoded_script)} | base64 -d >/tmp/azd-wireguard-command.sh; "
        "bash /tmp/azd-wireguard-command.sh; "
        "rc=$?; rm -f /tmp/azd-wireguard-command.sh; "
        "printf '\\nAZD_GUEST_EXIT_CODE=%s\\n' \"$rc\"; exit 0"
    )
    result = run(
        [
            "az",
            "vm",
            "run-command",
            "invoke",
            "--subscription",
            env("VPN_TARGET_SUBSCRIPTION_ID"),
            "--resource-group",
            env("VPN_RESOURCE_GROUP"),
            "--name",
            env("VPN_GATEWAY_VM_NAME"),
            "--command-id",
            "RunShellScript",
            "--scripts",
            wrapper,
            "-o",
            "json",
        ],
        check=False,
    )
    if result.returncode == 0:
        payload = json.loads(result.stdout)
        result.stdout = "\n".join(item.get("message", "") for item in payload.get("value", []))
        guest_match = re.search(r"AZD_GUEST_EXIT_CODE=(\d+)", result.stdout)
        if not guest_match:
            result.returncode = 1
            result.stderr = "Azure Run Command did not return the guest exit-code marker."
        else:
            result.returncode = int(guest_match.group(1))
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise VpnError(f"Azure guest command failed: {detail}")
    return result


def marker(output: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=(.*)$", output, re.MULTILINE)
    if not match:
        raise VpnError(f"Expected marker {name} was not returned by the gateway.")
    return match.group(1).strip()


def env(key: str, default: str = "") -> str:
    value = azd_get(key, default)
    if not value and not default:
        raise VpnError(f"Required azd environment value {key} is missing.")
    return value


def env_json(key: str) -> Any:
    raw = env(key)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise VpnError(f"{key} is not valid JSON: {exc}") from exc


def discover(dry_run: bool) -> None:
    require_tools("az", "azd", "ssh")
    account = az_json(["account", "show"])
    subscription_id = azd_get("VPN_TARGET_SUBSCRIPTION_ID", account["id"])
    ownership_id = azd_get("VPN_OWNERSHIP_ID") or str(uuid.uuid4())
    ensure_encryption_at_host(subscription_id, register=not dry_run)
    print(f"Using Azure subscription: {subscription_id}")

    existing_vnet_name = azd_get("VPN_VNET_NAME")
    existing_vnet_rg = azd_get("VPN_VNET_RESOURCE_GROUP")
    if existing_vnet_name and existing_vnet_rg:
        selected = {
            "name": existing_vnet_name,
            "resourceGroup": existing_vnet_rg,
        }
        print(
            f"Reusing existing VNet: {existing_vnet_name} "
            f"({existing_vnet_rg})"
        )
    else:
        vnets = az_json(
            [
                "network",
                "vnet",
                "list",
                "--subscription",
                subscription_id,
                "--query",
                "[].{name:name,resourceGroup:resourceGroup,location:location,id:id,addressPrefixes:addressSpace.addressPrefixes}",
            ]
        )
        selected = choose(
            "Existing VNets",
            vnets,
            lambda item: (
                f"{item['name']} | {item['resourceGroup']} | {item['location']} | "
                f"{', '.join(item.get('addressPrefixes') or [])}"
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
    selected["location"] = vnet["location"]
    selected["id"] = vnet["id"]
    default_vpn_rg = re.sub(
        r"[^A-Za-z0-9_.()-]",
        "-",
        f"rg-{selected['name']}-vpn",
    )[:90]
    vpn_resource_group = env_or_prompt(
        "VPN_RESOURCE_GROUP",
        "VPN resource group name",
        default_vpn_rg,
    )
    existing_vpn_rg = run(
        [
            "az",
            "group",
            "show",
            "--subscription",
            subscription_id,
            "--name",
            vpn_resource_group,
            "-o",
            "json",
        ],
        check=False,
    )
    if existing_vpn_rg.returncode == 0:
        existing = json.loads(existing_vpn_rg.stdout)
        if existing.get("tags", {}).get("vpn-owner") != ownership_id:
            raise VpnError(
                f"Resource group {vpn_resource_group} already exists and is not owned by this azd environment."
            )

    vnet_prefixes = [
        network(prefix, "Azure VNet prefix")
        for prefix in vnet["addressSpace"]["addressPrefixes"]
    ]
    subnets = vnet.get("subnets", [])
    used_subnets = [
        network(prefix, f"Subnet {subnet['name']} prefix")
        for subnet in subnets
        for prefix in (
            subnet.get("addressPrefixes")
            or ([subnet["addressPrefix"]] if subnet.get("addressPrefix") else [])
        )
    ]

    vpn_subnet_name = env_or_prompt(
        "VPN_SUBNET_NAME", "VPN subnet name", "wireguard-vpn-subnet"
    )
    existing_vpn_subnet = next(
        (
            subnet
            for subnet in subnets
            if subnet["name"].lower() == vpn_subnet_name.lower()
        ),
        None,
    )
    if existing_vpn_subnet:
        existing_nsg_id = existing_vpn_subnet.get("networkSecurityGroup", {}).get(
            "id", ""
        )
        if not existing_nsg_id:
            raise VpnError(
                f"Existing subnet {vpn_subnet_name} has no owned VPN NSG."
            )
        existing_nsg = az_json(["network", "nsg", "show", "--ids", existing_nsg_id])
        if existing_nsg.get("tags", {}).get("vpn-owner") != ownership_id:
            raise VpnError(
                f"Subnet {vpn_subnet_name} already exists and is not owned by this azd environment."
            )
        existing_prefix = (
            existing_vpn_subnet.get("addressPrefixes")
            or [existing_vpn_subnet.get("addressPrefix")]
        )[0]
        default_vpn_cidr = existing_prefix
    else:
        default_vpn_cidr = str(find_free_subnet(vnet_prefixes, used_subnets))
    vpn_subnet = network(
        env_or_prompt("VPN_SUBNET_CIDR", "VPN subnet CIDR", default_vpn_cidr),
        "VPN subnet CIDR",
    )
    if existing_vpn_subnet and str(vpn_subnet) != default_vpn_cidr:
        raise VpnError("An owned existing VPN subnet cannot be resized during reprovision.")
    if not any(vpn_subnet.subnet_of(prefix) for prefix in vnet_prefixes):
        raise VpnError("The VPN subnet must be contained by a selected VNet address prefix.")
    comparison_subnets = [
        existing
        for existing in used_subnets
        if not existing_vpn_subnet or existing != vpn_subnet
    ]
    if any(vpn_subnet.overlaps(existing) for existing in comparison_subnets):
        raise VpnError("The VPN subnet overlaps an existing subnet.")
    gateway_private_ip = str(list(vpn_subnet.hosts())[3])
    migrate_legacy_gateway(
        subscription_id,
        selected["resourceGroup"],
        vpn_resource_group,
        gateway_private_ip,
        ownership_id,
        execute=not dry_run,
    )

    print("\nExisting subnets:")
    for subnet in subnets:
        prefixes = subnet.get("addressPrefixes") or [subnet.get("addressPrefix", "")]
        name_lower = subnet["name"].lower()
        delegated = [
            delegation.get("serviceName", "")
            for delegation in subnet.get("delegations", [])
        ]
        excluded_reason = ""
        if subnet["name"] == "AzureBastionSubnet":
            excluded_reason = "Bastion"
        elif name_lower == vpn_subnet_name.lower():
            excluded_reason = "VPN"
        elif "private-endpoint" in name_lower or name_lower.startswith(("pe-", "pep-")):
            excluded_reason = "private endpoint"
        route_table = subnet.get("routeTable") or {}
        nsg = subnet.get("networkSecurityGroup") or {}
        print(
            f"  {subnet['name']}: {', '.join(prefixes)}"
            f" | NSG={parse_resource_id(nsg.get('id', '')).get('networksecuritygroups', '-')}"
            f" | route table={parse_resource_id(route_table.get('id', '')).get('routetables', '-')}"
            f" | delegations={','.join(delegated) or '-'}"
            f"{' | excluded: ' + excluded_reason if excluded_reason else ''}"
        )
    print(
        "\nPoint-to-site client mode uses source NAT on the Azure gateway, "
        "so existing workload/private-endpoint subnets do not need UDR or NSG changes."
    )
    selected_subnets: list[dict[str, Any]] = []

    default_tunnel = str(find_tunnel_network([*vnet_prefixes, vpn_subnet]))
    tunnel = network(
        env_or_prompt("VPN_TUNNEL_CIDR", "WireGuard tunnel CIDR", default_tunnel),
        "Tunnel CIDR",
    )
    if tunnel.prefixlen != 24 or not tunnel.subnet_of(ipaddress.ip_network("10.99.0.0/16")):
        raise VpnError("The tunnel must be a /24 within 10.99.0.0/16.")

    remote_access_mode = "client-config"
    remote_ssh_endpoint = ""
    remote_ssh_port = "22"
    remote_ssh_username = ""

    default_key, public_key = usable_ssh_key()
    key_path = default_key
    public_path = Path(f"{key_path}.pub")
    if not key_path.is_file() or not public_path.is_file():
        raise VpnError("The selected SSH private key and matching .pub file must both exist.")
    public_key = public_path.read_text(encoding="utf-8").strip()
    tunnel_hosts = list(tunnel.hosts())
    remote_network = network(f"{tunnel_hosts[1]}/32", "Client tunnel address")
    remote_lan_ip = tunnel_hosts[1]
    private_hostnames, linked_zones = discover_vnet_dns(subscription_id, vnet["id"])
    private_foundry_hostnames = [
        hostname
        for hostname in private_hostnames
        if any(
            suffix in hostname
            for suffix in (
                ".services.ai.azure.com",
                ".openai.azure.com",
                ".cognitiveservices.azure.com",
            )
        )
    ]
    resource_group_foundry_hostnames = discover_foundry_hostnames(
        subscription_id, selected["resourceGroup"]
    )
    foundry_hostnames = list(
        dict.fromkeys(
            [*resource_group_foundry_hostnames, *private_foundry_hostnames]
        )
    )
    if (
        resource_group_foundry_hostnames
        and resource_group_foundry_hostnames[0] not in private_foundry_hostnames
    ):
        print(
            f"WARNING: {resource_group_foundry_hostnames[0]} has no matching record "
            "in a linked Foundry private DNS zone and may resolve publicly."
        )
    print(f"\nPrivate DNS zones linked to the VNet: {', '.join(linked_zones) or 'none found'}")
    print(
        "Foundry hostnames discovered in the VNet resource group/private endpoints: "
        + (", ".join(foundry_hostnames) if foundry_hostnames else "none found")
    )
    azure_target_ip = ""
    azure_target_host = env_or_prompt(
        "VPN_AZURE_VALIDATION_HOSTNAME",
        "Private hostname to validate through the VPN",
        foundry_hostnames[0] if foundry_hostnames else "",
    )
    remote_target_ip = ""
    remote_target_host = ""
    client_name = re.sub(
        r"[^A-Za-z0-9_.-]",
        "-",
        env_or_prompt(
            "VPN_CLIENT_NAME",
            "WireGuard client profile name",
            os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "foundry-client",
        ),
    )

    route_tables: list[dict[str, Any]] = []
    route_index: dict[tuple[str, str], int] = {}
    shared_route_name = f"{vpn_subnet_name}-rt"
    route_name_prefix = f"wg-{ownership_id.split('-')[0]}"
    managed_route_names = {
        f"{route_name_prefix}-remote-network": str(remote_network),
        f"{route_name_prefix}-tunnel-network": str(tunnel),
    }
    existing_vpn_nsg = run(
        [
            "az",
            "network",
            "nsg",
            "show",
            "--subscription",
            subscription_id,
            "--resource-group",
            vpn_resource_group,
            "--name",
            f"{vpn_subnet_name}-nsg",
            "-o",
            "json",
        ],
        check=False,
    )
    if existing_vpn_nsg.returncode == 0:
        existing = json.loads(existing_vpn_nsg.stdout)
        if existing.get("tags", {}).get("vpn-owner") != ownership_id:
            raise VpnError(
                f"VPN NSG name {vpn_subnet_name}-nsg already exists and is not owned by this azd environment."
            )

    workload_configs: list[dict[str, Any]] = []
    workload_nsgs: list[dict[str, Any]] = []
    nsg_index: dict[tuple[str, str], int] = {}
    nsg_rules: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for subnet in selected_subnets:
        prefix = (subnet.get("addressPrefixes") or [subnet.get("addressPrefix")])[0]
        nsg_id = subnet.get("networkSecurityGroup", {}).get("id", "")
        if nsg_id:
            nsg_parts = parse_resource_id(nsg_id)
            nsg_name = nsg_parts["networksecuritygroups"]
            nsg_rg = nsg_parts["resourceGroup"]
            rules = az_json(
                [
                    "network",
                    "nsg",
                    "rule",
                    "list",
                    "--subscription",
                    subscription_id,
                    "--resource-group",
                    nsg_rg,
                    "--nsg-name",
                    nsg_name,
                ]
            )
            colliding_rules = [
                rule for rule in rules if rule.get("name") in MANAGED_RULE_NAMES
            ]
            if colliding_rules and len(colliding_rules) != len(MANAGED_RULE_NAMES):
                raise VpnError(
                    f"NSG {nsg_name} contains only some reserved WireGuard rule names."
                )
            create_nsg = False
            priority_base = (
                next(
                    rule["priority"]
                    for rule in colliding_rules
                    if rule["name"] == "AllowNestedInbound"
                )
                if colliding_rules
                else find_priority_base(rules)
            )
        else:
            nsg_name = f"{subnet['name']}-wireguard-nsg"
            nsg_rg = selected["resourceGroup"]
            create_nsg = True
            priority_base = 3000
            existing_generated_nsg = run(
                [
                    "az",
                    "network",
                    "nsg",
                    "show",
                    "--subscription",
                    subscription_id,
                    "--resource-group",
                    nsg_rg,
                    "--name",
                    nsg_name,
                    "-o",
                    "json",
                ],
                check=False,
            )
            if existing_generated_nsg.returncode == 0:
                existing = json.loads(existing_generated_nsg.stdout)
                if existing.get("tags", {}).get("vpn-owner") != ownership_id:
                    raise VpnError(
                        f"Generated NSG name {nsg_name} already exists and is not owned by this azd environment."
                    )

        route_id = subnet.get("routeTable", {}).get("id", "")
        if route_id:
            route_parts = parse_resource_id(route_id)
            route_name = route_parts["routetables"]
            route_rg = route_parts["resourceGroup"]
            create_route = False
            routes = az_json(
                [
                    "network",
                    "route-table",
                    "route",
                    "list",
                    "--subscription",
                    subscription_id,
                    "--resource-group",
                    route_rg,
                    "--route-table-name",
                    route_name,
                ]
            )
            colliding_routes = [
                route
                for route in routes
                if route.get("name") in managed_route_names
            ]
            for route in colliding_routes:
                if (
                    route.get("addressPrefix") != managed_route_names[route["name"]]
                    or route.get("nextHopType") != "VirtualAppliance"
                    or route.get("nextHopIpAddress") != gateway_private_ip
                ):
                    raise VpnError(
                        f"Route table {route_name} contains a conflicting route named {route['name']}."
                    )
        else:
            route_name = shared_route_name
            route_rg = selected["resourceGroup"]
            create_route = True
            existing_generated_route_table = run(
                [
                    "az",
                    "network",
                    "route-table",
                    "show",
                    "--subscription",
                    subscription_id,
                    "--resource-group",
                    route_rg,
                    "--name",
                    route_name,
                    "-o",
                    "json",
                ],
                check=False,
            )
            if existing_generated_route_table.returncode == 0:
                existing = json.loads(existing_generated_route_table.stdout)
                if existing.get("tags", {}).get("vpn-owner") != ownership_id:
                    raise VpnError(
                        f"Generated route table name {route_name} already exists and is not owned by this azd environment."
                    )

        nsg_key = (nsg_rg.lower(), nsg_name.lower())
        if nsg_key not in nsg_index:
            nsg_index[nsg_key] = len(workload_nsgs)
            workload_nsgs.append(
                {
                    "name": nsg_name,
                    "resourceGroup": nsg_rg,
                    "create": create_nsg,
                    "priorityBase": priority_base,
                    "subnetPrefixes": [],
                }
            )
            if nsg_id:
                nsg_rules[nsg_key] = rules
        group = workload_nsgs[nsg_index[nsg_key]]
        if group["create"] != create_nsg or group["priorityBase"] != priority_base:
            raise VpnError(f"Inconsistent discovery state for shared NSG {nsg_name}.")
        group["subnetPrefixes"].append(prefix)

        route_key = (route_rg.lower(), route_name.lower())
        if route_key not in route_index:
            route_index[route_key] = len(route_tables)
            route_tables.append(
                {
                    "name": route_name,
                    "resourceGroup": route_rg,
                    "create": create_route,
                }
            )
        workload_configs.append(
            {
                "name": subnet["name"],
                "prefix": prefix,
                "nsgName": nsg_name,
                "nsgResourceGroup": nsg_rg,
                "createNsg": create_nsg,
                "nsgPriorityBase": priority_base,
                "nsgGroupIndex": nsg_index[nsg_key],
                "routeTableName": route_name,
                "routeTableResourceGroup": route_rg,
                "createRouteTable": create_route,
                "routeTableIndex": route_index[route_key],
            }
        )

    for nsg_key, group_index in nsg_index.items():
        rules = nsg_rules.get(nsg_key, [])
        rules_by_name = {rule["name"]: rule for rule in rules}
        if not MANAGED_RULE_NAMES.issubset(rules_by_name):
            continue
        group = workload_nsgs[group_index]
        expected_rules = {
            "AllowNestedInbound": (
                "Inbound",
                [str(remote_network)],
                sorted(group["subnetPrefixes"]),
                group["priorityBase"],
            ),
            "AllowTunnelInbound": (
                "Inbound",
                [str(tunnel)],
                sorted(group["subnetPrefixes"]),
                group["priorityBase"] + 10,
            ),
            "AllowNestedOutbound": (
                "Outbound",
                sorted(group["subnetPrefixes"]),
                [str(remote_network)],
                group["priorityBase"] + 20,
            ),
            "AllowTunnelOutbound": (
                "Outbound",
                sorted(group["subnetPrefixes"]),
                [str(tunnel)],
                group["priorityBase"] + 30,
            ),
        }
        for rule_name, expected in expected_rules.items():
            rule = rules_by_name[rule_name]
            actual = (
                rule.get("direction"),
                address_values(rule, "sourceAddressPrefix", "sourceAddressPrefixes"),
                address_values(
                    rule, "destinationAddressPrefix", "destinationAddressPrefixes"
                ),
                rule.get("priority"),
            )
            if (
                actual != expected
                or rule.get("access") != "Allow"
                or rule.get("protocol") != "*"
                or rule.get("sourcePortRange") != "*"
                or rule.get("destinationPortRange") != "*"
                or f"[vpn-owner:{ownership_id}]" not in rule.get("description", "")
            ):
                raise VpnError(
                    f"NSG {group['name']} contains a conflicting rule named {rule_name}."
                )

    tunnel_hosts = list(tunnel.hosts())
    values = {
        "VPN_TARGET_SUBSCRIPTION_ID": subscription_id,
        "VPN_MODE": "client",
        "VPN_VNET_RESOURCE_GROUP": selected["resourceGroup"],
        "VPN_RESOURCE_GROUP": vpn_resource_group,
        "VPN_LOCATION": selected["location"],
        "VPN_VNET_NAME": selected["name"],
        "VPN_VNET_PREFIXES_JSON": json.dumps(
            [str(prefix) for prefix in vnet_prefixes], separators=(",", ":")
        ),
        "VPN_SUBNET_NAME": vpn_subnet_name,
        "VPN_SUBNET_CIDR": str(vpn_subnet),
        "VPN_GATEWAY_PRIVATE_IP": gateway_private_ip,
        "VPN_TUNNEL_CIDR": str(tunnel),
        "VPN_AZURE_TUNNEL_IP": str(tunnel_hosts[0]),
        "VPN_REMOTE_TUNNEL_IP": str(tunnel_hosts[1]),
        "VPN_REMOTE_NETWORK_CIDR": str(remote_network),
        "VPN_REMOTE_ACCESS_MODE": remote_access_mode,
        "VPN_REMOTE_SSH_ENDPOINT": remote_ssh_endpoint,
        "VPN_REMOTE_SSH_PORT": remote_ssh_port,
        "VPN_REMOTE_SSH_USERNAME": remote_ssh_username,
        "VPN_REMOTE_SSH_KEY_PATH": str(key_path),
        "VPN_REMOTE_LAN_IP": str(remote_lan_ip),
        "VPN_ADMIN_SSH_PUBLIC_KEY": public_key,
        "VPN_AZURE_ADMIN_USERNAME": "wireguardadmin",
        "VPN_GATEWAY_VM_SIZE": "Standard_D2als_v6",
        "VPN_WORKLOAD_SUBNETS_JSON": json.dumps(
            workload_configs, separators=(",", ":")
        ),
        "VPN_WORKLOAD_NSGS_JSON": json.dumps(workload_nsgs, separators=(",", ":")),
        "VPN_ROUTE_TABLES_JSON": json.dumps(route_tables, separators=(",", ":")),
        "VPN_OWNERSHIP_ID": ownership_id,
        "VPN_ROUTE_NAME_PREFIX": route_name_prefix,
        "VPN_CLIENT_NAME": client_name,
        "VPN_PRIVATE_DNS_ZONES_JSON": json.dumps(linked_zones, separators=(",", ":")),
        "VPN_PRIVATE_HOSTNAMES_JSON": json.dumps(
            private_hostnames, separators=(",", ":")
        ),
        "VPN_AZURE_VALIDATION_IP": azure_target_ip,
        "VPN_AZURE_VALIDATION_HOSTNAME": azure_target_host,
        "VPN_REMOTE_VALIDATION_IP": remote_target_ip,
        "VPN_REMOTE_VALIDATION_HOSTNAME": remote_target_host,
    }
    remote_scope = "client-config"
    if azd_get("VPN_REMOTE_STATE_SCOPE") != remote_scope:
        values.update(
            {
                "VPN_REMOTE_STATE_SCOPE": remote_scope,
                "VPN_REMOTE_WG_REPLACE_CONFIRMED": "false",
                "VPN_REMOTE_WG_BACKUP_PATH": "",
                "VPN_REMOTE_PRIOR_STATE_JSON": "",
                "VPN_REMOTE_CLEANUP_COMPLETE": "false",
            }
        )

    print("\nResolved VPN configuration:")
    for key in (
        "VPN_VNET_NAME",
        "VPN_VNET_PREFIXES_JSON",
        "VPN_SUBNET_CIDR",
        "VPN_GATEWAY_PRIVATE_IP",
        "VPN_TUNNEL_CIDR",
        "VPN_CLIENT_NAME",
        "VPN_PRIVATE_DNS_ZONES_JSON",
        "VPN_AZURE_VALIDATION_HOSTNAME",
    ):
        print(f"  {key}={values[key]}")
    if dry_run:
        print("\nDry run complete; azd environment was not changed.")
        return
    for key, value in values.items():
        azd_set(key, value)
    print("\nDiscovery complete. Configuration was saved to the current azd environment.")


def associate_workload_subnets() -> None:
    associations = env_json("VPN_WORKLOAD_ASSOCIATIONS")
    for association in associations:
        if not association["attachNsg"] and not association["attachRouteTable"]:
            continue
        args = [
            "az",
            "network",
            "vnet",
            "subnet",
            "update",
            "--subscription",
            env("VPN_TARGET_SUBSCRIPTION_ID"),
            "--resource-group",
            env("VPN_VNET_RESOURCE_GROUP"),
            "--vnet-name",
            env("VPN_VNET_NAME"),
            "--name",
            association["subnetName"],
        ]
        if association["attachNsg"]:
            args.extend(["--network-security-group", association["nsgResourceId"]])
        if association["attachRouteTable"]:
            args.extend(["--route-table", association["routeTableResourceId"]])
        run([*args, "-o", "none"])


def bootstrap_script() -> str:
    return r"""set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard iptables-persistent
install -d -m 700 /etc/wireguard
if [ ! -s /etc/wireguard/privatekey ]; then
  umask 077
  wg genkey > /etc/wireguard/privatekey
fi
wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
chmod 600 /etc/wireguard/privatekey
cat >/etc/sysctl.d/99-azd-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null
iptables -P FORWARD ACCEPT
netfilter-persistent save >/dev/null
printf 'WG_PUBLIC_KEY=%s\n' "$(cat /etc/wireguard/publickey)"
"""


def configure_client() -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    client_name = env("VPN_CLIENT_NAME")
    key_file = RESULTS_DIR / f".{client_name}.key"
    if key_file.exists():
        client_private_key = key_file.read_text(encoding="utf-8").strip()
        private_key = X25519PrivateKey.from_private_bytes(
            base64.b64decode(client_private_key)
        )
    else:
        private_key = X25519PrivateKey.generate()
        client_private_key = base64.b64encode(
            private_key.private_bytes(
                serialization.Encoding.Raw,
                serialization.PrivateFormat.Raw,
                serialization.NoEncryption(),
            )
        ).decode("ascii")
        key_file.write_text(client_private_key + "\n", encoding="utf-8")
        key_file.chmod(0o600)
    client_public_key = base64.b64encode(
        private_key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
    ).decode("ascii")

    azure_bootstrap = azure_run(
        bootstrap_script()
        + r"""
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq dnsmasq dnsutils
"""
    )
    azure_public_key = marker(azure_bootstrap.stdout, "WG_PUBLIC_KEY")
    azure_address = (
        f"{env('VPN_AZURE_TUNNEL_IP')}/"
        f"{network(env('VPN_TUNNEL_CIDR'), 'Tunnel CIDR').prefixlen}"
    )
    vnet_prefixes = json.loads(env("VPN_VNET_PREFIXES_JSON"))
    forward_rules = "\n".join(
        [
            (
                f"iptables -C FORWARD -i wg0 -o \"$dev\" -s {env('VPN_TUNNEL_CIDR')} "
                f"-d {prefix} -j ACCEPT 2>/dev/null || "
                f"iptables -A FORWARD -i wg0 -o \"$dev\" -s {env('VPN_TUNNEL_CIDR')} "
                f"-d {prefix} -j ACCEPT\n"
                f"iptables -C FORWARD -i \"$dev\" -o wg0 -s {prefix} "
                f"-d {env('VPN_TUNNEL_CIDR')} -m conntrack --ctstate ESTABLISHED,RELATED "
                f"-j ACCEPT 2>/dev/null || "
                f"iptables -A FORWARD -i \"$dev\" -o wg0 -s {prefix} "
                f"-d {env('VPN_TUNNEL_CIDR')} -m conntrack --ctstate ESTABLISHED,RELATED "
                f"-j ACCEPT\n"
                f"iptables -t nat -C POSTROUTING -o \"$dev\" -s {env('VPN_TUNNEL_CIDR')} "
                f"-d {prefix} -j MASQUERADE 2>/dev/null || "
                f"iptables -t nat -A POSTROUTING -o \"$dev\" -s {env('VPN_TUNNEL_CIDR')} "
                f"-d {prefix} -j MASQUERADE"
            )
            for prefix in vnet_prefixes
        ]
    )
    azure_config = f"""set -euo pipefail
private_key=$(cat /etc/wireguard/privatekey)
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = {azure_address}
ListenPort = 51820
PrivateKey = $private_key

[Peer]
PublicKey = {client_public_key}
AllowedIPs = {env('VPN_REMOTE_TUNNEL_IP')}/32
EOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0 >/dev/null
systemctl restart wg-quick@wg0
cat >/etc/dnsmasq.d/azd-wireguard.conf <<EOF
interface=wg0
listen-address={env('VPN_AZURE_TUNNEL_IP')}
bind-dynamic
server=168.63.129.16
cache-size=1000
EOF
systemctl enable dnsmasq >/dev/null
systemctl restart dnsmasq
dev=$(ip -4 route show default | awk 'NR==1 {{print $5}}')
test -n "$dev"
{forward_rules}
netfilter-persistent save >/dev/null
wg show wg0
"""
    azure_run(azure_config)

    allowed_ips = ", ".join([*vnet_prefixes, f"{env('VPN_AZURE_TUNNEL_IP')}/32"])
    client_config = f"""[Interface]
PrivateKey = {client_private_key}
Address = {env('VPN_REMOTE_TUNNEL_IP')}/32
DNS = {env('VPN_AZURE_TUNNEL_IP')}

[Peer]
PublicKey = {azure_public_key}
Endpoint = {env('VPN_GATEWAY_PUBLIC_IP')}:51820
AllowedIPs = {allowed_ips}
PersistentKeepalive = 25
"""
    config_file = RESULTS_DIR / f"{client_name}.conf"
    config_file.write_text(client_config, encoding="utf-8")
    config_file.chmod(0o600)
    private_hostnames = json.loads(env("VPN_PRIVATE_HOSTNAMES_JSON", "[]"))
    validation_hostname = env("VPN_AZURE_VALIDATION_HOSTNAME", "")
    dns_hostnames = sorted(
        {
            hostname
            for hostname in [*private_hostnames, validation_hostname]
            if hostname
        }
    )
    dns_script = """# Run this script from an elevated PowerShell session after activating WireGuard.
$dnsServer = '{dns_server}'
$comment = 'Managed by azd WireGuard VPN sample'
$hostnames = @(
{hostnames}
)

foreach ($hostname in $hostnames) {{
    Get-DnsClientNrptRule |
        Where-Object {{
            $_.Comment -eq $comment -and $_.Namespace -contains $hostname
        }} |
        Remove-DnsClientNrptRule -Force
    Add-DnsClientNrptRule -Namespace $hostname -NameServers $dnsServer -Comment $comment
}}

Clear-DnsClientCache
""".format(
        dns_server=env("VPN_AZURE_TUNNEL_IP"),
        hostnames="\n".join(f"    '{hostname}'" for hostname in dns_hostnames),
    )
    dns_script_file = RESULTS_DIR / f"{client_name}-dns.ps1"
    dns_script_file.write_text(dns_script, encoding="utf-8")
    windows_path = run(["wslpath", "-w", str(config_file)], check=False)
    windows_dns_path = run(["wslpath", "-w", str(dns_script_file)], check=False)
    display_path = (
        windows_path.stdout.strip()
        if windows_path.returncode == 0 and windows_path.stdout.strip()
        else str(config_file)
    )
    display_dns_path = (
        windows_dns_path.stdout.strip()
        if windows_dns_path.returncode == 0 and windows_dns_path.stdout.strip()
        else str(dns_script_file)
    )
    print(f"WireGuard client profile created: {display_path}")
    print(f"Windows private DNS policy script created: {display_dns_path}")
    print("Import this profile into WireGuard for Windows and activate the tunnel.")
    print("Then run the DNS policy script from an elevated PowerShell session.")


def configure() -> None:
    require_tools("az", "azd")
    associate_workload_subnets()
    if env("VPN_MODE", "client") == "client":
        configure_client()
        return
    require_tools("ssh")
    azd_set("VPN_REMOTE_CLEANUP_COMPLETE", "false")

    existing = remote_run(
        """set -e
if [ -f /etc/wireguard/wg0.conf ]; then echo WG_CONFIG_EXISTS=yes; else echo WG_CONFIG_EXISTS=no; fi
printf 'WG_CONFIG_OWNER=%s\n' "$(sed -n 's/^# vpn-owner://p' /etc/wireguard/wg0.conf 2>/dev/null | head -1)"
printf 'WG_SERVICE_ACTIVE=%s\n' "$(systemctl is-active wg-quick@wg0 2>/dev/null || true)"
printf 'WG_SERVICE_ENABLED=%s\n' "$(systemctl is-enabled wg-quick@wg0 2>/dev/null || true)"
printf 'IP_FORWARD=%s\n' "$(sysctl -n net.ipv4.ip_forward)"
printf 'FORWARD_POLICY=%s\n' "$(iptables -S FORWARD | awk '$1 == "-P" { print $3 }')"
"""
    )
    remote_scope = (
        "local"
        if env("VPN_REMOTE_ACCESS_MODE", "ssh") == "local"
        else (
            f"{env('VPN_REMOTE_SSH_USERNAME')}@{env('VPN_REMOTE_SSH_ENDPOINT')}:"
            f"{env('VPN_REMOTE_SSH_PORT', '22')}"
        )
    )
    if azd_get("VPN_REMOTE_STATE_SCOPE") != remote_scope:
        raise VpnError("Remote state scope no longer matches the configured SSH endpoint.")
    if not azd_get("VPN_REMOTE_PRIOR_STATE_JSON"):
        prior_state = {
            "configExisted": marker(existing.stdout, "WG_CONFIG_EXISTS") == "yes",
            "serviceActive": marker(existing.stdout, "WG_SERVICE_ACTIVE"),
            "serviceEnabled": marker(existing.stdout, "WG_SERVICE_ENABLED"),
            "ipForward": marker(existing.stdout, "IP_FORWARD"),
            "forwardPolicy": marker(existing.stdout, "FORWARD_POLICY") or "DROP",
        }
        azd_set("VPN_REMOTE_PRIOR_STATE_JSON", json.dumps(prior_state, separators=(",", ":")))
    config_exists = marker(existing.stdout, "WG_CONFIG_EXISTS") == "yes"
    config_owner = marker(existing.stdout, "WG_CONFIG_OWNER")
    owned_config = config_owner == env("VPN_OWNERSHIP_ID")
    if config_exists and not owned_config:
        already_confirmed = azd_get("VPN_REMOTE_WG_REPLACE_CONFIRMED").lower() == "true"
        if not already_confirmed:
            if not sys.stdin.isatty() or not confirm(
                "Remote /etc/wireguard/wg0.conf exists. Back it up and replace it?"
            ):
                raise VpnError("Remote WireGuard configuration replacement was not approved.")
            azd_set("VPN_REMOTE_WG_REPLACE_CONFIRMED", "true")
        if not azd_get("VPN_REMOTE_WG_BACKUP_PATH"):
            backup_result = remote_run(
                """set -e
backup="/etc/wireguard/wg0.conf.pre-azd-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a /etc/wireguard/wg0.conf "$backup"
printf 'WG_BACKUP_PATH=%s\n' "$backup"
"""
            )
            azd_set(
                "VPN_REMOTE_WG_BACKUP_PATH",
                marker(backup_result.stdout, "WG_BACKUP_PATH"),
            )
        backup_path = env("VPN_REMOTE_WG_BACKUP_PATH")
        if remote_run(f"test -f {shlex.quote(backup_path)}", check=False).returncode != 0:
            raise VpnError(
                f"The recorded remote WireGuard backup no longer exists: {backup_path}"
            )
    elif owned_config:
        prior_state = json.loads(env("VPN_REMOTE_PRIOR_STATE_JSON"))
        backup_path = azd_get("VPN_REMOTE_WG_BACKUP_PATH")
        if prior_state.get("configExisted") and not backup_path:
            raise VpnError(
                "The remote gateway has sample-owned configuration but its original backup path is missing."
            )
        if backup_path:
            backup_check = remote_run(
                f"test -f {shlex.quote(backup_path)}", check=False
            )
            if backup_check.returncode != 0:
                raise VpnError(
                    f"The recorded remote WireGuard backup no longer exists: {backup_path}"
                )

    azure_bootstrap = azure_run(bootstrap_script())
    remote_bootstrap = remote_run(bootstrap_script())
    azure_public_key = marker(azure_bootstrap.stdout, "WG_PUBLIC_KEY")
    remote_public_key = marker(remote_bootstrap.stdout, "WG_PUBLIC_KEY")

    remote_allowed = ", ".join(
        [*json.loads(env("VPN_VNET_PREFIXES_JSON")), f"{env('VPN_AZURE_TUNNEL_IP')}/32"]
    )
    azure_address = f"{env('VPN_AZURE_TUNNEL_IP')}/{network(env('VPN_TUNNEL_CIDR'), 'Tunnel CIDR').prefixlen}"
    remote_address = f"{env('VPN_REMOTE_TUNNEL_IP')}/{network(env('VPN_TUNNEL_CIDR'), 'Tunnel CIDR').prefixlen}"

    azure_config = f"""set -euo pipefail
private_key=$(cat /etc/wireguard/privatekey)
cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = {azure_address}
ListenPort = 51820
PrivateKey = $private_key

[Peer]
PublicKey = {remote_public_key}
AllowedIPs = {env('VPN_REMOTE_NETWORK_CIDR')}, {env('VPN_REMOTE_TUNNEL_IP')}/32
EOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0 >/dev/null
systemctl restart wg-quick@wg0
wg show wg0
"""
    azure_run(azure_config)

    remote_config = f"""set -euo pipefail
private_key=$(cat /etc/wireguard/privatekey)
cat >/etc/wireguard/wg0.conf <<EOF
# vpn-owner:{env('VPN_OWNERSHIP_ID')}
[Interface]
Address = {remote_address}
PrivateKey = $private_key

[Peer]
PublicKey = {azure_public_key}
Endpoint = {env('VPN_GATEWAY_PUBLIC_IP')}:51820
AllowedIPs = {remote_allowed}
PersistentKeepalive = 25
EOF
chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0 >/dev/null
systemctl restart wg-quick@wg0
wg show wg0
"""
    remote_run(remote_config)
    print("WireGuard is configured on both gateways.")


def validation_script(peer_ip: str, target_ip: str, target_hostname: str) -> str:
    quoted_peer = shlex.quote(peer_ip)
    quoted_ip = shlex.quote(target_ip)
    quoted_hostname = shlex.quote(target_hostname)
    return f"""set +e
failed=0
echo '## system'
systemctl is-active wg-quick@wg0 || failed=1
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || failed=1
iptables -S FORWARD | tee /tmp/wg-forward-policy
grep -q '^-P FORWARD ACCEPT$' /tmp/wg-forward-policy || failed=1
echo '## wireguard'
wg show wg0 || failed=1
echo '## tunnel-ping'
ping -c 4 -W 3 {quoted_peer} || failed=1
echo '## target-ip'
if [ -n {quoted_ip} ]; then
  ip route get {quoted_ip} || failed=1
  ping -c 4 -W 3 {quoted_ip} || failed=1
else
  echo SKIPPED
fi
echo '## target-hostname'
if [ -n {quoted_hostname} ]; then
  getent ahostsv4 {quoted_hostname} || failed=1
  ping -c 4 -W 3 {quoted_hostname} || failed=1
else
  echo SKIPPED
fi
echo '## nat'
iptables -t nat -S
exit "$failed"
"""


def validation_checks() -> tuple[list[str], list[str]]:
    failures: list[str] = []
    checks: list[str] = []
    associations = {
        item["subnetName"]: item for item in env_json("VPN_WORKLOAD_ASSOCIATIONS")
    }

    nic = az_json(
        [
            "network",
            "nic",
            "show",
            "--ids",
            env("VPN_GATEWAY_NIC_RESOURCE_ID"),
        ]
    )
    checks.append(f"NIC IP forwarding: {nic.get('enableIPForwarding')}")
    checks.append(f"NIC-level NSG: {nic.get('networkSecurityGroup') or 'none'}")
    if not nic.get("enableIPForwarding"):
        failures.append("Azure NIC IP forwarding is disabled.")
    if nic.get("networkSecurityGroup"):
        failures.append("The gateway NIC unexpectedly has an NIC-level NSG.")

    pip = az_json(
        [
            "network",
            "public-ip",
            "show",
            "--ids",
            env("VPN_GATEWAY_PUBLIC_IP_RESOURCE_ID"),
        ]
    )
    checks.append(
        f"Public IP SKU/allocation: {pip.get('sku', {}).get('name')}/"
        f"{pip.get('publicIPAllocationMethod')}"
    )
    if pip.get("sku", {}).get("name") != "Standard":
        failures.append("The WireGuard public IP is not Standard SKU.")
    if pip.get("publicIPAllocationMethod") != "Static":
        failures.append("The WireGuard public IP is not static.")

    vm = az_json(
        [
            "vm",
            "show",
            "--ids",
            env("VPN_GATEWAY_VM_RESOURCE_ID"),
        ]
    )
    encryption = vm.get("securityProfile", {}).get("encryptionAtHost")
    checks.append(f"Encryption at host: {encryption}")
    if encryption is not True:
        failures.append("Encryption at host is not enabled.")

    for workload in env_json("VPN_WORKLOAD_SUBNETS_JSON"):
        subnet = az_json(
            [
                "network",
                "vnet",
                "subnet",
                "show",
                "--subscription",
                env("VPN_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                env("VPN_VNET_RESOURCE_GROUP"),
                "--vnet-name",
                env("VPN_VNET_NAME"),
                "--name",
                workload["name"],
            ]
        )
        checks.append(
            f"Subnet {workload['name']}: NSG={subnet.get('networkSecurityGroup', {}).get('id', 'none')}, "
            f"route table={subnet.get('routeTable', {}).get('id', 'none')}"
        )
        expected_association = associations[workload["name"]]
        actual_nsg_id = subnet.get("networkSecurityGroup", {}).get("id", "").lower()
        actual_route_id = subnet.get("routeTable", {}).get("id", "").lower()
        if actual_nsg_id != expected_association["nsgResourceId"].lower():
            failures.append(f"Subnet {workload['name']} has the wrong NSG association.")
        if actual_route_id != expected_association["routeTableResourceId"].lower():
            failures.append(f"Subnet {workload['name']} has the wrong route-table association.")

    for nsg in env_json("VPN_WORKLOAD_NSGS_JSON"):
        rules = az_json(
            [
                "network",
                "nsg",
                "rule",
                "list",
                "--subscription",
                env("VPN_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                nsg["resourceGroup"],
                "--nsg-name",
                nsg["name"],
            ]
        )
        rules_by_name = {rule["name"]: rule for rule in rules}
        missing_rules = MANAGED_RULE_NAMES.difference(rules_by_name)
        if missing_rules:
            failures.append(
                f"NSG {nsg['name']} is missing rules: {', '.join(sorted(missing_rules))}."
            )
        expected_rules = {
            "AllowNestedInbound": (
                "Inbound",
                [env("VPN_REMOTE_NETWORK_CIDR")],
                sorted(nsg["subnetPrefixes"]),
                nsg["priorityBase"],
            ),
            "AllowTunnelInbound": (
                "Inbound",
                [env("VPN_TUNNEL_CIDR")],
                sorted(nsg["subnetPrefixes"]),
                nsg["priorityBase"] + 10,
            ),
            "AllowNestedOutbound": (
                "Outbound",
                sorted(nsg["subnetPrefixes"]),
                [env("VPN_REMOTE_NETWORK_CIDR")],
                nsg["priorityBase"] + 20,
            ),
            "AllowTunnelOutbound": (
                "Outbound",
                sorted(nsg["subnetPrefixes"]),
                [env("VPN_TUNNEL_CIDR")],
                nsg["priorityBase"] + 30,
            ),
        }
        for rule_name, expected in expected_rules.items():
            if rule_name not in rules_by_name:
                continue
            rule = rules_by_name[rule_name]
            actual = (
                rule.get("direction"),
                address_values(rule, "sourceAddressPrefix", "sourceAddressPrefixes"),
                address_values(
                    rule, "destinationAddressPrefix", "destinationAddressPrefixes"
                ),
                rule.get("priority"),
            )
            if (
                actual != expected
                or rule.get("access") != "Allow"
                or rule.get("protocol") != "*"
                or rule.get("sourcePortRange") != "*"
                or rule.get("destinationPortRange") != "*"
                or f"[vpn-owner:{env('VPN_OWNERSHIP_ID')}]" not in rule.get(
                    "description", ""
                )
            ):
                failures.append(f"NSG rule {nsg['name']}/{rule_name} has unexpected properties.")

    for route_table in env_json("VPN_ROUTE_TABLES_JSON"):
        routes = az_json(
            [
                "network",
                "route-table",
                "route",
                "list",
                "--subscription",
                env("VPN_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                route_table["resourceGroup"],
                "--route-table-name",
                route_table["name"],
            ]
        )
        routes_by_name = {route["name"]: route for route in routes}
        route_prefix = env("VPN_ROUTE_NAME_PREFIX")
        for route_name, prefix in (
            (f"{route_prefix}-remote-network", env("VPN_REMOTE_NETWORK_CIDR")),
            (f"{route_prefix}-tunnel-network", env("VPN_TUNNEL_CIDR")),
        ):
            route = routes_by_name.get(route_name)
            if not route:
                failures.append(f"Route table {route_table['name']} is missing {route_name}.")
                continue
            if (
                route.get("addressPrefix") != prefix
                or route.get("nextHopType") != "VirtualAppliance"
                or route.get("nextHopIpAddress") != env("VPN_GATEWAY_PRIVATE_IP")
            ):
                failures.append(
                    f"Route table {route_table['name']}/{route_name} has unexpected properties."
                )

    return checks, failures


def validate_client() -> None:
    checks, failures = validation_checks()
    hostname = azd_get("VPN_AZURE_VALIDATION_HOSTNAME")
    dns_check = (
        f"dig +short @{shlex.quote(env('VPN_AZURE_TUNNEL_IP'))} "
        f"{shlex.quote(hostname)} | tee /tmp/wg-dns-result; "
        "test -s /tmp/wg-dns-result || failed=1; "
        "python3 - <<'PY' || failed=1\n"
        "import ipaddress\n"
        "from pathlib import Path\n"
        "values = Path('/tmp/wg-dns-result').read_text().splitlines()\n"
        "ips = []\n"
        "for value in values:\n"
        "    try:\n"
        "        ips.append(ipaddress.ip_address(value.rstrip('.')))\n"
        "    except ValueError:\n"
        "        pass\n"
        "if not ips or not all(ip.is_private for ip in ips):\n"
        "    raise SystemExit('Hostname did not resolve exclusively to private IPs')\n"
        "PY"
        if hostname
        else "echo 'DNS hostname validation skipped.'"
    )
    gateway_result = azure_run(
        f"""set +e
failed=0
systemctl is-active wg-quick@wg0 || failed=1
systemctl is-active dnsmasq || failed=1
[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || failed=1
wg show wg0
echo '## DNS'
{dns_check}
echo '## NAT'
iptables -t nat -S POSTROUTING | tee /tmp/wg-nat
grep -q -- '-s {env('VPN_TUNNEL_CIDR')}.*MASQUERADE' /tmp/wg-nat || failed=1
latest=$(wg show wg0 latest-handshakes | awk '{{print $2}}')
if [ -z "$latest" ] || [ "$latest" = "0" ]; then
  echo 'CLIENT_HANDSHAKE=pending'
else
  echo 'CLIENT_HANDSHAKE=active'
fi
exit "$failed"
""",
        check=False,
    )
    handshake = (
        "active"
        if "CLIENT_HANDSHAKE=active" in gateway_result.stdout
        else "pending client profile activation"
    )
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    report = RESULTS_DIR / f"wireguard-validation-{timestamp}.md"
    status = "READY" if not failures and gateway_result.returncode == 0 else "FAIL"
    report.write_text(
        "\n".join(
            [
                "# WireGuard point-to-site validation",
                "",
                f"- Timestamp (UTC): `{timestamp}`",
                f"- Gateway status: **{status}**",
                f"- Client handshake: **{handshake}**",
                f"- Client profile: `{RESULTS_DIR / (env('VPN_CLIENT_NAME') + '.conf')}`",
                f"- Azure VNet: `{env('VPN_VNET_NAME')}`",
                f"- Azure prefixes: `{env('VPN_VNET_PREFIXES_JSON')}`",
                f"- Linked private DNS zones: `{azd_get('VPN_PRIVATE_DNS_ZONES_JSON', '[]')}`",
                "",
                "## Azure resource checks",
                "",
                *[f"- {item}" for item in checks],
                "",
                "## Azure resource failures",
                "",
                *([f"- {item}" for item in failures] if failures else ["- None"]),
                "",
                "## Gateway checks",
                "",
                "```text",
                gateway_result.stdout.strip(),
                gateway_result.stderr.strip(),
                "```",
                "",
                "Import and activate the generated profile in WireGuard for Windows, "
                "then rerun `uv run python scripts/vpn.py validate` to confirm an active handshake.",
            ]
        ),
        encoding="utf-8",
    )
    print(f"Validation report: {report}")
    if status == "FAIL":
        raise VpnError("Point-to-site gateway validation failed. See the report.")


def validate() -> None:
    require_tools("az", "azd")
    if env("VPN_MODE", "client") == "client":
        validate_client()
        return
    require_tools("ssh")
    checks, failures = validation_checks()
    azure_result = azure_run(
        validation_script(
            env("VPN_REMOTE_TUNNEL_IP"),
            azd_get("VPN_REMOTE_VALIDATION_IP"),
            azd_get("VPN_REMOTE_VALIDATION_HOSTNAME"),
        ),
        check=False,
    )
    remote_result = remote_run(
        validation_script(
            env("VPN_AZURE_TUNNEL_IP"),
            azd_get("VPN_AZURE_VALIDATION_IP"),
            azd_get("VPN_AZURE_VALIDATION_HOSTNAME"),
        ),
        check=False,
    )
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    report = RESULTS_DIR / f"wireguard-validation-{timestamp}.md"
    status = (
        "PASS"
        if not failures and azure_result.returncode == 0 and remote_result.returncode == 0
        else "FAIL"
    )
    report.write_text(
        "\n".join(
            [
                "# WireGuard VPN validation",
                "",
                f"- Timestamp (UTC): `{timestamp}`",
                f"- Overall status: **{status}**",
                f"- Azure VNet: `{env('VPN_VNET_NAME')}`",
                f"- Azure prefixes: `{env('VPN_VNET_PREFIXES_JSON')}`",
                f"- Remote network: `{env('VPN_REMOTE_NETWORK_CIDR')}`",
                f"- Tunnel network: `{env('VPN_TUNNEL_CIDR')}`",
                "",
                "## Azure resource checks",
                "",
                *[f"- {item}" for item in checks],
                "",
                "## Azure resource failures",
                "",
                *([f"- {item}" for item in failures] if failures else ["- None"]),
                "",
                "## Azure gateway tests",
                "",
                "```text",
                azure_result.stdout.strip(),
                azure_result.stderr.strip(),
                "```",
                "",
                "## Remote gateway tests",
                "",
                "```text",
                remote_result.stdout.strip(),
                remote_result.stderr.strip(),
                "```",
                "",
                "## No-NAT return-path prerequisite",
                "",
                (
                    f"The remote LAN router (or each remote host) must route "
                    f"`{env('VPN_VNET_PREFIXES_JSON')}` through remote gateway "
                    f"`{env('VPN_REMOTE_LAN_IP')}`. The sample does not add masquerade/SNAT."
                ),
                "",
                (
                    "DNS results reflect the existing resolvers on both gateways. "
                    "This sample does not provision DNS forwarding."
                ),
            ]
        ),
        encoding="utf-8",
    )
    print(f"Validation report: {report}")
    if status != "PASS":
        raise VpnError("One or more validation checks failed. See the report for details.")


def cleanup() -> None:
    require_tools("az", "azd")
    workloads = env_json("VPN_WORKLOAD_SUBNETS_JSON")
    associations = env_json("VPN_WORKLOAD_ASSOCIATIONS")
    by_name = {item["name"]: item for item in workloads}
    for association in associations:
        workload = by_name[association["subnetName"]]
        subnet = az_json(
            [
                "network",
                "vnet",
                "subnet",
                "show",
                "--subscription",
                env("VPN_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                env("VPN_VNET_RESOURCE_GROUP"),
                "--vnet-name",
                env("VPN_VNET_NAME"),
                "--name",
                workload["name"],
            ]
        )
        remove_properties: list[str] = []
        current_nsg = subnet.get("networkSecurityGroup", {}).get("id", "").lower()
        current_route = subnet.get("routeTable", {}).get("id", "").lower()
        if (
            workload["createNsg"]
            and current_nsg == association["nsgResourceId"].lower()
        ):
            remove_properties.append("networkSecurityGroup")
        if (
            workload["createRouteTable"]
            and current_route == association["routeTableResourceId"].lower()
        ):
            remove_properties.append("routeTable")
        if remove_properties:
            args = [
                "az",
                "network",
                "vnet",
                "subnet",
                "update",
                "--subscription",
                env("VPN_TARGET_SUBSCRIPTION_ID"),
                "--resource-group",
                env("VPN_VNET_RESOURCE_GROUP"),
                "--vnet-name",
                env("VPN_VNET_NAME"),
                "--name",
                workload["name"],
            ]
            for property_name in remove_properties:
                args.extend(["--remove", property_name])
            run([*args, "-o", "none"])

    if (
        (
            env("VPN_REMOTE_ACCESS_MODE", "ssh") == "local"
            or azd_get("VPN_REMOTE_SSH_ENDPOINT")
        )
        and azd_get("VPN_REMOTE_CLEANUP_COMPLETE").lower() != "true"
    ):
        backup = azd_get("VPN_REMOTE_WG_BACKUP_PATH")
        prior_state = json.loads(azd_get("VPN_REMOTE_PRIOR_STATE_JSON", "{}"))
        remote_script = "systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true\n"
        if backup:
            remote_script += (
                f"if [ -f {shlex.quote(backup)} ]; then "
                f"mv {shlex.quote(backup)} /etc/wireguard/wg0.conf; fi\n"
            )
        else:
            remote_script += "rm -f /etc/wireguard/wg0.conf\n"
        remote_script += "rm -f /etc/sysctl.d/99-azd-wireguard-forward.conf\n"
        if prior_state:
            remote_script += (
                f"sysctl -w net.ipv4.ip_forward={shlex.quote(str(prior_state.get('ipForward', '0')))} "
                ">/dev/null\n"
                f"iptables -P FORWARD {shlex.quote(prior_state.get('forwardPolicy', 'DROP'))}\n"
                "netfilter-persistent save >/dev/null\n"
            )
            if prior_state.get("serviceEnabled") == "enabled":
                remote_script += "systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true\n"
            if prior_state.get("serviceActive") == "active":
                remote_script += "systemctl start wg-quick@wg0\n"
        remote_run(remote_script)
        azd_set("VPN_REMOTE_CLEANUP_COMPLETE", "true")

    if azd_get("VPN_REMOTE_CLEANUP_COMPLETE").lower() == "true":
        azd_set("VPN_REMOTE_WG_BACKUP_PATH", "")
        azd_set("VPN_REMOTE_PRIOR_STATE_JSON", "")
        azd_set("VPN_REMOTE_WG_REPLACE_CONFIRMED", "false")

    route_failures: list[str] = []
    for route_table in env_json("VPN_ROUTE_TABLES_JSON"):
        route_prefix = env("VPN_ROUTE_NAME_PREFIX")
        for route_name, expected_prefix in (
            (f"{route_prefix}-remote-network", env("VPN_REMOTE_NETWORK_CIDR")),
            (f"{route_prefix}-tunnel-network", env("VPN_TUNNEL_CIDR")),
        ):
            current = run(
                [
                    "az",
                    "network",
                    "route-table",
                    "route",
                    "show",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--resource-group",
                    route_table["resourceGroup"],
                    "--route-table-name",
                    route_table["name"],
                    "--name",
                    route_name,
                    "-o",
                    "json",
                ],
                check=False,
            )
            if current.returncode != 0:
                if "not found" not in (current.stderr or current.stdout).lower():
                    route_failures.append(f"{route_table['name']}/{route_name}")
                continue
            route = json.loads(current.stdout)
            if (
                route.get("addressPrefix") != expected_prefix
                or route.get("nextHopType") != "VirtualAppliance"
                or route.get("nextHopIpAddress") != env("VPN_GATEWAY_PRIVATE_IP")
            ):
                route_failures.append(
                    f"{route_table['name']}/{route_name} (definition changed)"
                )
                continue
            result = run(
                [
                    "az",
                    "network",
                    "route-table",
                    "route",
                    "delete",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--resource-group",
                    route_table["resourceGroup"],
                    "--route-table-name",
                    route_table["name"],
                    "--name",
                    route_name,
                ],
                check=False,
            )
            message = (result.stderr or result.stdout).lower()
            if result.returncode != 0 and "not found" not in message:
                route_failures.append(f"{route_table['name']}/{route_name}")
        if route_table["create"] and not route_failures:
            run_allow_not_found(
                [
                    "az",
                    "network",
                    "route-table",
                    "delete",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--resource-group",
                    route_table["resourceGroup"],
                    "--name",
                    route_table["name"],
                ]
            )
    if route_failures:
        raise VpnError(
            "Refusing to delete the gateway because these routes could not be removed: "
            + ", ".join(route_failures)
        )

    for nsg in env_json("VPN_WORKLOAD_NSGS_JSON"):
        if nsg["create"]:
            continue
        expected_rules = {
            "AllowNestedInbound": (
                "Inbound",
                [env("VPN_REMOTE_NETWORK_CIDR")],
                sorted(nsg["subnetPrefixes"]),
                nsg["priorityBase"],
            ),
            "AllowTunnelInbound": (
                "Inbound",
                [env("VPN_TUNNEL_CIDR")],
                sorted(nsg["subnetPrefixes"]),
                nsg["priorityBase"] + 10,
            ),
            "AllowNestedOutbound": (
                "Outbound",
                sorted(nsg["subnetPrefixes"]),
                [env("VPN_REMOTE_NETWORK_CIDR")],
                nsg["priorityBase"] + 20,
            ),
            "AllowTunnelOutbound": (
                "Outbound",
                sorted(nsg["subnetPrefixes"]),
                [env("VPN_TUNNEL_CIDR")],
                nsg["priorityBase"] + 30,
            ),
        }
        for rule_name, expected in expected_rules.items():
            current = run(
                [
                    "az",
                    "network",
                    "nsg",
                    "rule",
                    "show",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--resource-group",
                    nsg["resourceGroup"],
                    "--nsg-name",
                    nsg["name"],
                    "--name",
                    rule_name,
                    "-o",
                    "json",
                ],
                check=False,
            )
            if current.returncode != 0:
                if "not found" in (current.stderr or current.stdout).lower():
                    continue
                raise VpnError(
                    f"Failed to inspect managed NSG rule {nsg['name']}/{rule_name}."
                )
            rule = json.loads(current.stdout)
            actual = (
                rule.get("direction"),
                address_values(rule, "sourceAddressPrefix", "sourceAddressPrefixes"),
                address_values(
                    rule, "destinationAddressPrefix", "destinationAddressPrefixes"
                ),
                rule.get("priority"),
            )
            if (
                actual != expected
                or rule.get("access") != "Allow"
                or rule.get("protocol") != "*"
                or rule.get("sourcePortRange") != "*"
                or rule.get("destinationPortRange") != "*"
                or f"[vpn-owner:{env('VPN_OWNERSHIP_ID')}]" not in rule.get(
                    "description", ""
                )
            ):
                raise VpnError(
                    f"Refusing to delete changed NSG rule {nsg['name']}/{rule_name}."
                )
            result = run(
                [
                    "az",
                    "network",
                    "nsg",
                    "rule",
                    "delete",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--resource-group",
                    nsg["resourceGroup"],
                    "--nsg-name",
                    nsg["name"],
                    "--name",
                    rule_name,
                ],
                check=False,
            )
            message = (result.stderr or result.stdout).lower()
            if result.returncode != 0 and "not found" not in message:
                raise VpnError(
                    f"Failed to remove managed NSG rule {nsg['name']}/{rule_name}."
                )

    run_allow_not_found(
        [
            "az",
            "vm",
            "delete",
            "--ids",
            azd_get("VPN_GATEWAY_VM_RESOURCE_ID"),
            "--yes",
        ]
    )
    for resource_id, command in (
        (azd_get("VPN_GATEWAY_NIC_RESOURCE_ID"), ["az", "network", "nic", "delete"]),
        (
            azd_get("VPN_GATEWAY_PUBLIC_IP_RESOURCE_ID"),
            ["az", "network", "public-ip", "delete"],
        ),
    ):
        if resource_id:
            run_allow_not_found([*command, "--ids", resource_id])

    run_allow_not_found(
        [
            "az",
            "network",
            "vnet",
            "subnet",
            "delete",
            "--subscription",
            env("VPN_TARGET_SUBSCRIPTION_ID"),
            "--resource-group",
            env("VPN_VNET_RESOURCE_GROUP"),
            "--vnet-name",
            env("VPN_VNET_NAME"),
            "--name",
            env("VPN_SUBNET_NAME"),
        ]
    )
    nsg_ids = [
        item["resourceId"]
        for item in env_json("VPN_WORKLOAD_NSGS")
        if item["created"]
    ]
    if vpn_nsg := azd_get("VPN_NSG_RESOURCE_ID"):
        nsg_ids.append(vpn_nsg)
    for nsg_id in nsg_ids:
        run_allow_not_found(["az", "network", "nsg", "delete", "--ids", nsg_id])
    vpn_rg = run(
        [
            "az",
            "group",
            "show",
            "--subscription",
            env("VPN_TARGET_SUBSCRIPTION_ID"),
            "--name",
            env("VPN_RESOURCE_GROUP"),
            "-o",
            "json",
        ],
        check=False,
    )
    if vpn_rg.returncode == 0:
        resource_group = json.loads(vpn_rg.stdout)
        if resource_group.get("tags", {}).get("vpn-owner") == env("VPN_OWNERSHIP_ID"):
            run_allow_not_found(
                [
                    "az",
                    "group",
                    "delete",
                    "--subscription",
                    env("VPN_TARGET_SUBSCRIPTION_ID"),
                    "--name",
                    env("VPN_RESOURCE_GROUP"),
                    "--yes",
                    "--no-wait",
                ]
            )
    print("Sample-owned VPN resources and associations were removed.")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    discover_parser = subparsers.add_parser("discover")
    discover_parser.add_argument("--dry-run", action="store_true")
    subparsers.add_parser("configure")
    subparsers.add_parser("validate")
    subparsers.add_parser("cleanup")
    args = parser.parse_args()

    try:
        if args.command == "discover":
            discover(args.dry_run)
        elif args.command == "configure":
            configure()
        elif args.command == "validate":
            validate()
        elif args.command == "cleanup":
            cleanup()
    except VpnError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
