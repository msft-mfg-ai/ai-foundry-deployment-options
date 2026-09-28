# WireGuard VPN troubleshooting

Use commands from `options-infra/vpn`. Do not print `.conf`, hidden `.key`, `.azure/*/.env`, or unfiltered `azd env get-values` output.

## Generated results

- `results/<client-name>.conf`: WireGuard client profile; mode `0600`; contains the client private key.
- `results/.<client-name>.key`: reusable client private key; mode `0600`.
- `results/<client-name>-dns.ps1`: elevated Windows NRPT setup for discovered private hostnames.
- `results/wireguard-validation-<timestamp>.md`: resource, service, DNS, NAT, and handshake report.

`<client-name>` is the selected VNet resource-group name with unsupported filename characters replaced by `-`.

## Diagnose in order

1. Confirm the active azd environment and safe target values:
   ```bash
   AZD_DISABLE_AGENT_DETECT=1 azd env list
   for key in VPN_TARGET_SUBSCRIPTION_ID VPN_VNET_RESOURCE_GROUP VPN_VNET_NAME VPN_RESOURCE_GROUP VPN_SUBNET_NAME VPN_SUBNET_CIDR VPN_TUNNEL_CIDR VPN_AZURE_VALIDATION_HOSTNAME; do
     printf '%s=' "$key"
     AZD_DISABLE_AGENT_DETECT=1 azd env get-value "$key"
   done
   ```
2. Reconstruct and verify the exact existing VNet resource ID:
   ```bash
   sub="$(AZD_DISABLE_AGENT_DETECT=1 azd env get-value VPN_TARGET_SUBSCRIPTION_ID)"
   rg="$(AZD_DISABLE_AGENT_DETECT=1 azd env get-value VPN_VNET_RESOURCE_GROUP)"
   vnet="$(AZD_DISABLE_AGENT_DETECT=1 azd env get-value VPN_VNET_NAME)"
   az network vnet show --subscription "$sub" --resource-group "$rg" --name "$vnet" --query id -o tsv
   ```
3. Run the canonical validator:
   ```bash
   uv run python scripts/vpn.py validate
   ```
4. Read the newest validation report without copying private profile content:
   ```bash
   ls -1t results/wireguard-validation-*.md | head -1
   ```

## Failure map

| Symptom | Check and action |
|---|---|
| Handshake pending | Activate the generated profile in WireGuard for Windows; verify the profile endpoint matches the gateway public IP and UDP 51820 is allowed locally; rerun `validate`. Pending before first activation is expected. |
| Handshake absent after activation | Check VM power state, Standard/static public IP, subnet NSG UDP 51820 rule, and client endpoint. Run `az vm get-instance-view` using the safe azd values. |
| Handshake active, private route fails | Verify the profile `AllowedIPs` conceptually contains all selected VNet prefixes and the Azure tunnel IP; do not display the profile. Rerun `configure`, then `validate` to check forwarding and MASQUERADE. |
| DNS fails | Confirm the target private DNS zones are linked to the selected VNet, `dnsmasq` is active in the report, and the validation hostname resolves privately from Azure. Regenerate and rerun the generated elevated `*-dns.ps1` NRPT script. |
| DNS resolves publicly | Fix the private DNS zone/link or choose a correct private validation hostname; the VPN cannot make an unlinked/private record exist. |
| Browser differs from `Resolve-DnsName` | Clear Windows DNS/browser caches, rerun the generated NRPT script elevated, and confirm corporate DNS policy is not overriding the exact-host rules. |
| `discover` rejects subnet | Choose a canonical IPv4 CIDR contained in a VNet prefix and non-overlapping with every current subnet. The default finder selects the first free `/27`. |
| Tunnel CIDR rejected | Use a non-overlapping `/24` within `10.99.0.0/16`; discovery searches `10.99.x.0/24`. |
| Existing VPN RG/subnet/NSG rejected | Do not take ownership. Use a new dedicated azd environment/resource-group/subnet name or restore the matching `vpn-owner` environment. |
| Encryption-at-host error | Confirm the subscription supports the feature and that the provider registration requested by discovery completes before retrying. |

## Safe client-profile regeneration

Run:

```bash
uv run python scripts/vpn.py configure
uv run python scripts/vpn.py validate
```

This reuses `results/.<client-name>.key` when present and rewrites the profile and NRPT script. Rotate the client key only when explicitly requested: identify the active client name, delete only its hidden key and generated profile, then rerun `configure`. Never display, log, paste, or commit either file.
