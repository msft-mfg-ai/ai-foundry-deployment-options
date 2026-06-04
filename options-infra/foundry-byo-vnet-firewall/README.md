# Foundry BYO VNet + Azure Firewall egress

Clone of [`foundry-two-projects`](../foundry-two-projects/) that routes **agent-subnet** and **pe-subnet** outbound traffic through an Azure Firewall (Basic SKU). Built from the shared modules:

- [`modules/networking/vnet.bicep`](../modules/networking/vnet.bicep) — extended to optionally create `AzureFirewallSubnet`/`AzureFirewallManagementSubnet` and attach a route table to agent + pe subnets
- [`modules/networking/firewall.bicep`](../modules/networking/firewall.bicep) — reusable firewall module with bundled-default application + network rule collections (FQDN allowlist for `login.microsoftonline.com`, `*.identity.azure.net`, `*.azurecontainerapps.dev`, `mcr.microsoft.com`, `*.login.microsoft.com`, `*.documents.azure.com`; deny port 80 from agent subnet)

## Order of operations (Bicep)

To avoid the chicken-and-egg between subnet route-table attachment and the firewall existing:

1. **Empty route table** is created first.
2. `vnet.bicep` builds the VNet with all subnets — agent/pe reference the empty route table; `AzureFirewallSubnet` + `AzureFirewallManagementSubnet` are sized in.
3. `firewall.bicep` deploys the firewall using the firewall subnets, then populates the existing route table with `0.0.0.0/0` and the agent CIDR route (via `createRouteTable: false`).

No `deploymentScripts` are used — entirely Bicep + AVM.

## Deployment

```bash
# Azure Developer CLI
azd up

# OR Azure CLI
az deployment group create \
  --resource-group "rg-foundry-byo-vnet-firewall" \
  --template-file main.bicep \
  --parameters main.bicepparam
```

## Parameters

| Name | Default | Notes |
|---|---|---|
| `projectsCount` | `2` | Foundry projects to create |
| `apiServices` | `[]` | External MCP/OpenAPI services (same as `foundry-two-projects`) |

All VNet/subnet prefixes, firewall SKU, and firewall rules use defaults baked into the shared modules. Override at the module level if needed.

## Outputs

In addition to the standard `foundry-two-projects` outputs:

- `FIREWALL_PRIVATE_IP` — IP the route table forwards through
- `ROUTE_TABLE_ID` — for attaching additional subnets to the same route table
