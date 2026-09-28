---
name: wireguard-vpn
description: Configure, deploy, inspect, validate, troubleshoot, regenerate client profiles for, and safely remove the repository's point-to-site WireGuard VPN overlay for an existing private Azure AI Foundry VNet. Use for requests to deploy/configure/manage VPN, connect a workstation to a private Foundry VNet, validate WireGuard, regenerate a client profile, diagnose VPN DNS/handshake/routing, inspect VPN status, or remove the VPN overlay under options-infra/vpn.
---

# Manage the WireGuard VPN

Operate only the exact sample in `options-infra/vpn`. Read its `README.md`, `azure.yaml`, `main.bicep`, `main.bicepparam`, `scripts/vpn.py`, referenced WireGuard modules, and tests before changing its behavior.

## Protect ownership boundaries

- Treat the selected VNet, Foundry resources, private endpoints, and private DNS zones as user-owned. Never delete or broadly modify them.
- Explain that deployment adds one dedicated subnet to the existing VNet. It creates the VM, NIC, Standard static public IP, NSG, and related sample-owned resources in a separate VPN resource group.
- Preserve unrelated worktree changes. Do not edit templates, environments, or deploy resources unless the user explicitly requests that operation.
- Use one dedicated azd environment per target VNet. Never repurpose an environment across VNets.
- Prefix every `azd` invocation with `AZD_DISABLE_AGENT_DETECT=1`.
- Use `uv sync` and `uv run`; never use `pip` or create `requirements.txt`.
- Never print, paste, commit, or expose generated `.conf`, hidden `.key`, `.azure/*/.env`, private keys, or secrets.

## Establish the target

Run from the repository root unless a command changes directory:

```bash
cd options-infra/vpn
uv sync
AZD_DISABLE_AGENT_DETECT=1 azd env list
```

For a new target, create a clearly named environment:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd env new <dedicated-env-name>
```

Before provision, cleanup, or teardown:

1. Confirm the active Azure subscription with `az account show`.
2. Read only these non-secret azd values individually: `VPN_TARGET_SUBSCRIPTION_ID`, `VPN_VNET_RESOURCE_GROUP`, `VPN_VNET_NAME`, `VPN_RESOURCE_GROUP`, `VPN_SUBNET_NAME`, and CIDRs.
3. Resolve the VNet with `az network vnet show` and verify its exact `/subscriptions/.../virtualNetworks/...` resource ID with the operator's intended target.
4. Inspect all VNet prefixes and subnets. Accept only a canonical subnet CIDR contained by the VNet and non-overlapping with every existing subnet. Let `scripts/vpn.py discover` select its first free `/27` by default.
5. Ensure the `10.99.x.0/24` tunnel network overlaps neither VNet prefixes nor the VPN subnet.

## Deploy

Use the azd hooks; do not duplicate their logic:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd up
```

`preprovision` runs `uv run python scripts/vpn.py discover`. It discovers the VNet, free subnet/tunnel CIDRs, linked private DNS zones, private endpoints, Foundry hostnames, SSH public key, ownership ID, and writes configuration to the active azd environment. `postprovision` runs `configure` then `validate`.

After deployment, report:

- The dedicated azd environment and verified VNet resource ID.
- The dedicated VPN resource group and subnet CIDR.
- The generated profile and elevated DNS script paths, without displaying contents.
- The newest validation report status and whether the client handshake is active or pending.

## Configure or regenerate the profile

```bash
uv run python scripts/vpn.py configure
uv run python scripts/vpn.py validate
```

`configure` configures WireGuard, `dnsmasq`, forwarding, and source NAT on the VM; creates `results/<client-name>.conf`; preserves/reuses `results/.<client-name>.key`; and writes `results/<client-name>-dns.ps1`. Import the profile into WireGuard for Windows, activate it, then run the generated PowerShell script elevated.

Rotate a client key only on explicit request. Delete only that client's hidden key and profile, never show their contents, then rerun `configure`. Do not regenerate Azure resources merely to regenerate a profile.

## Validate, troubleshoot, or inspect

Run the canonical validation first:

```bash
uv run python scripts/vpn.py validate
```

Interpret `results/wireguard-validation-<timestamp>.md`:

- `READY` plus pending handshake is normal before activating the client.
- The report validates public IP SKU/allocation, NIC forwarding/no NIC NSG, host encryption, WireGuard and `dnsmasq`, private DNS, source NAT, and handshake state.
- After activation, rerun validation and require an active handshake.

From Windows, validate the chosen private hostname:

```powershell
Resolve-DnsName <private-foundry-hostname>
Test-NetConnection <private-foundry-hostname> -Port 443
```

Require private-IP DNS answers. Read [references/troubleshooting.md](references/troubleshooting.md) for generated-file semantics, safe status commands, and the DNS/handshake/routing failure map.

Run repository tests only when modifying or verifying the VPN implementation:

```bash
uv run python -m unittest discover -s tests -v
```

## Tear down safely

Do not proceed until the active azd environment's subscription, VNet resource ID, VPN resource group, subnet name, and ownership ID match the intended overlay. Confirm no unrelated resource uses the dedicated subnet or VPN resource group.

Then invoke the supported workflow:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd down
```

The `predown` hook runs `uv run python scripts/vpn.py cleanup`. It deletes the sample VM/NIC/public IP, the dedicated subnet from the existing VNet, the owned NSG, and the separate VPN resource group only when its `vpn-owner` tag matches. It must not delete the existing VNet, Foundry deployment, private endpoints, private DNS zones, or unrelated resources.

Use `uv run python scripts/vpn.py cleanup` directly only to recover from a failed `azd down`, after performing the same target and ownership checks.
