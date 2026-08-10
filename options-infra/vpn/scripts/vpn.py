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
RESULTS_DIR = Path(os.environ.get("VPN_RESULTS_DIR", ROOT / "results")).resolve()


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


def discover(dry_run: bool) -> None:
    require_tools("az", "azd")
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

    print("\nExisting subnets:")
    for subnet in subnets:
        prefixes = subnet.get("addressPrefixes") or [subnet.get("addressPrefix", "")]
        print(f"  {subnet['name']}: {', '.join(prefixes)}")
    print(
        "\nPoint-to-site client mode uses source NAT on the Azure gateway, "
        "so existing workload/private-endpoint subnets do not need UDR or NSG changes."
    )

    default_tunnel = str(find_tunnel_network([*vnet_prefixes, vpn_subnet]))
    tunnel = network(
        env_or_prompt("VPN_TUNNEL_CIDR", "WireGuard tunnel CIDR", default_tunnel),
        "Tunnel CIDR",
    )
    if tunnel.prefixlen != 24 or not tunnel.subnet_of(ipaddress.ip_network("10.99.0.0/16")):
        raise VpnError("The tunnel must be a /24 within 10.99.0.0/16.")

    _, public_key = usable_ssh_key()
    tunnel_hosts = list(tunnel.hosts())
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
    azure_target_host = env_or_prompt(
        "VPN_AZURE_VALIDATION_HOSTNAME",
        "Private hostname to validate through the VPN",
        foundry_hostnames[0] if foundry_hostnames else "",
    )
    client_name = re.sub(
        r"[^A-Za-z0-9_.-]",
        "-",
        env_or_prompt(
            "VPN_CLIENT_NAME",
            "WireGuard client profile name",
            os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or "foundry-client",
        ),
    )

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

    values = {
        "VPN_TARGET_SUBSCRIPTION_ID": subscription_id,
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
        "VPN_CLIENT_TUNNEL_IP": str(tunnel_hosts[1]),
        "VPN_ADMIN_SSH_PUBLIC_KEY": public_key,
        "VPN_AZURE_ADMIN_USERNAME": "wireguardadmin",
        "VPN_GATEWAY_VM_SIZE": "Standard_B1ls",
        "VPN_OWNERSHIP_ID": ownership_id,
        "VPN_CLIENT_NAME": client_name,
        "VPN_PRIVATE_DNS_ZONES_JSON": json.dumps(linked_zones, separators=(",", ":")),
        "VPN_PRIVATE_HOSTNAMES_JSON": json.dumps(
            private_hostnames, separators=(",", ":")
        ),
        "VPN_AZURE_VALIDATION_HOSTNAME": azure_target_host,
    }

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


def configure() -> None:
    require_tools("az", "azd")
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
AllowedIPs = {env('VPN_CLIENT_TUNNEL_IP')}/32
EOF
chmod 600 /etc/wireguard/wg0.conf
cat >/etc/dnsmasq.d/azd-wireguard.conf <<EOF
interface=wg0
listen-address={env('VPN_AZURE_TUNNEL_IP')}
bind-dynamic
server=168.63.129.16
cache-size=1000
EOF
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat >/etc/systemd/system/dnsmasq.service.d/after-wg.conf <<EOF
[Unit]
After=network-online.target wg-quick@wg0.service
Wants=network-online.target
Requires=wg-quick@wg0.service

[Service]
Restart=on-failure
RestartSec=5s
EOF
systemctl daemon-reload
systemctl enable wg-quick@wg0 dnsmasq >/dev/null
systemctl restart wg-quick@wg0
systemctl restart dnsmasq
systemctl is-active --quiet wg-quick@wg0
systemctl is-active --quiet dnsmasq
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
Address = {env('VPN_CLIENT_TUNNEL_IP')}/32
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

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {{
    throw 'This script must run from an elevated PowerShell session.'
}}

Get-DnsClientNrptRule |
    Where-Object Comment -eq $comment |
    Remove-DnsClientNrptRule -Force

foreach ($hostname in $hostnames) {{
    Add-DnsClientNrptRule -Namespace $hostname -NameServers $dnsServer -Comment $comment
}}

Clear-DnsClientCache

foreach ($hostname in $hostnames) {{
    $answers = Resolve-DnsName $hostname -Type A -DnsOnly
    $addresses = @($answers | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
    if ($addresses.Count -eq 0) {{
        throw "No A record returned for $hostname through $dnsServer."
    }}
    Write-Host "$hostname -> $($addresses -join ', ')"
}}
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


def validation_checks() -> tuple[list[str], list[str]]:
    failures: list[str] = []
    checks: list[str] = []
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

    return checks, failures


def validate() -> None:
    require_tools("az", "azd")
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
ss -ulnp | grep -q '{env('VPN_AZURE_TUNNEL_IP')}:53' || failed=1
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


def cleanup() -> None:
    require_tools("az", "azd")
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
    if vpn_nsg := azd_get("VPN_NSG_RESOURCE_ID"):
        run_allow_not_found(["az", "network", "nsg", "delete", "--ids", vpn_nsg])
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
    print("Sample-owned VPN resources were removed.")


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
