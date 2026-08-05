# Point-to-site WireGuard access for a private Foundry VNet

This azd sample lets a developer workstation reach an existing Azure VNet so Azure AI Foundry accounts with public access disabled can be used from a desktop browser.

It deploys:

- An Ubuntu 24.04 WireGuard gateway VM using the AVM virtual-machine module.
- A dedicated, sample-owned VPN resource group for the VM, NIC, public IP, and NSG.
- A Standard static public IP on UDP 51820.
- A dedicated VPN subnet and subnet NSG.
- NIC IP forwarding, host encryption, and no NIC-level NSG.
- `dnsmasq` on the gateway, forwarding client DNS queries to Azure DNS (`168.63.129.16`).
- Source NAT from the WireGuard client network into the selected VNet.
- A WireGuard client profile for import into WireGuard for Windows.

NAT is intentional for this point-to-site scenario. Private endpoints and other Azure resources see the gateway's VNet address, so existing workload and private-endpoint subnets do not need UDR or NSG changes.

## Prerequisites

- Azure CLI, Azure Developer CLI, `uv`, and WSL/Linux.
- WireGuard for Windows installed on the desktop that will open the Foundry UI.
- An active `az login` with permission to deploy compute/network resources into the selected VNet resource group.
- A matching SSH key pair in WSL `~/.ssh` for emergency Azure VM access.
- The subscription must support encryption at host.
- Private DNS zones for the Foundry deployment must already be linked to the selected VNet.

## Deploy

```bash
cd options-infra/vpn
azd env new
AZD_DISABLE_AGENT_DETECT=1 azd up
```

Discovery asks you to:

1. Select the existing Foundry VNet.
2. Confirm the separate VPN resource group name.
3. Confirm a free VPN subnet CIDR.
4. Confirm a `10.99.x.0/24` WireGuard tunnel network.
5. Name the generated client profile.
6. Confirm the DNS validation hostname, defaulted to an `AIServices` Foundry account in the VNet resource group.

On subsequent `azd up` runs, discovery reuses values already stored in the current azd environment and only prompts for missing settings.

The script discovers:

- VNet address prefixes and existing subnets.
- Private endpoints in the VNet.
- Private DNS zones linked to the VNet.
- Foundry, Azure OpenAI, and Cognitive Services private hostnames.

It does **not** ask for workload subnets, a remote LAN CIDR, an SSH endpoint, or remote VM credentials.

## Connect from Windows

After deployment, the generated profile is written to:

```text
options-infra/vpn/results/<client-name>.conf
```

The deployment prints the equivalent Windows path. In WireGuard for Windows:

1. Select **Add Tunnel**.
2. Import the generated `.conf`.
3. Activate the tunnel.
4. Run the generated `<client-name>-dns.ps1` script from an elevated PowerShell session.
5. Open the Azure AI Foundry UI in the Windows browser.

The client profile routes only:

- The selected Azure VNet prefixes.
- The Azure WireGuard tunnel address.

It does not route general internet traffic through Azure.

## DNS

The profile sets its DNS server to the Azure WireGuard tunnel address. The gateway forwards those requests to Azure-provided DNS from inside the VNet, which makes every private DNS zone linked to that VNet available to the client.

The generated PowerShell script adds exact Windows Name Resolution Policy Table (NRPT) rules for discovered private hostnames. This ensures corporate DNS policies and multi-homed DNS resolution do not bypass the VPN DNS server.

To test from Windows after activating the tunnel:

```powershell
Resolve-DnsName <foundry-name>.services.ai.azure.com
Test-NetConnection <foundry-name>.services.ai.azure.com -Port 443
```

The hostname should resolve to a private IP in the selected VNet/private-endpoint address space.

## Validation

The postprovision hook verifies:

- Standard/static public IP.
- NIC forwarding and absence of an NIC NSG.
- Host encryption.
- WireGuard and `dnsmasq` services.
- Azure DNS resolution for the selected private hostname.
- Source NAT rules for every VNet prefix.

It writes a report to `results/wireguard-validation-<timestamp>.md`. Before the Windows profile is activated, the report shows the client handshake as pending. After activation, rerun:

```bash
uv run python scripts/vpn.py validate
```

## Teardown

```bash
AZD_DISABLE_AGENT_DETECT=1 azd down
```

The predown hook deletes the sample-owned VPN resource group and the VPN subnet linked into the existing VNet. It does not modify or delete the existing VNet, Foundry deployment, private endpoints, or private DNS zones.

## Shared modules

- `../modules/compute/wireguard-gateway-vm.bicep`
- `../modules/networking/wireguard-vpn-nsg.bicep`
- `../modules/networking/wireguard-vpn-subnet.bicep`
