# Custom DNS for an existing Foundry VNet

This azd sample deploys [Technitium DNS Server](https://github.com/TechnitiumSoftware/DnsServer) on Azure Container Instances (ACI) and configures authoritative records through the Technitium HTTP API.

Azure Container Apps is not used because its ingress does not support UDP. A DNS server used by an Azure VNet must accept both UDP and TCP on port 53.

## Resources

- One Linux ACI container group exposing UDP/TCP 53 and HTTPS 53443.
- One Azure Storage account and file share mounted at `/etc/dns` for persistent configuration.
- In `Private` mode, a dedicated `/24` ACI-delegated subnet and NAT gateway.
- A self-signed Technitium management certificate.

During preprovision, the sample snapshots all non-SOA/NS record sets from every Azure Private DNS zone linked to the selected VNet. Postprovision creates those zones in Technitium and writes the captured records into them. This is a hardcoded snapshot; rerun `azd up` to pick up Azure Private DNS changes.

Private deployments forward other queries to Azure DNS at `168.63.129.16` and allow recursion only for private clients. Recursion is disabled for public deployments, preventing an open recursive resolver.

## Configure records

Set records before deployment:

```bash
azd env set CUSTOM_DNS_RECORDS_JSON '[
  {"zone":"services.ai.azure.com","name":"my-foundry","type":"A","value":"10.10.2.4","ttl":300},
  {"zone":"services.ai.azure.com","name":"project","type":"CNAME","value":"my-foundry.services.ai.azure.com","ttl":300}
]'
```

Relative names are expanded using `zone`. Manual records are applied after discovered records, so they can override a discovered A or CNAME record set. Re-running `azd up` is idempotent.

## Deploy

```bash
cd options-infra/custom-dns
azd env new
azd env set CUSTOM_DNS_DEPLOYMENT_MODE Public
azd env set CUSTOM_DNS_APPLY_TO_VNET false
AZD_DISABLE_AGENT_DETECT=1 azd up
```

Discovery asks for the existing Foundry VNet and a sample-owned resource group. It generates and retains the Technitium administrator password in the local azd environment.

Supported deployment modes:

- `Public`: ACI receives a public IP and DNS label. Use this for initial testing.
- `Private`: ACI is injected into a new `/24` subnet in the existing VNet. A NAT gateway provides required outbound connectivity. Run deployment and API configuration from a workstation that can reach the VNet.

The management endpoint is written to `CUSTOM_DNS_API_URL`. Technitium uses a self-signed certificate, so browsers display a certificate warning.

## Apply to the VNet

Set `CUSTOM_DNS_APPLY_TO_VNET=true` before `azd up` to update the selected VNet after records are configured:

```bash
azd env set CUSTOM_DNS_APPLY_TO_VNET true
AZD_DISABLE_AGENT_DETECT=1 azd up
```

The hook saves the VNet's previous DNS server list and restores it during `azd down`. Existing VMs and other VNet-connected workloads may need DHCP lease renewal or restart before they use the new DNS server.

For a public deployment, ACI's public IP can change when the container group is recreated. Each `azd up` reapplies the current IP when `CUSTOM_DNS_APPLY_TO_VNET=true`.

## Teardown

```bash
AZD_DISABLE_AGENT_DETECT=1 azd down
```

The predown hook restores the prior VNet DNS settings, removes the private ACI subnet when present, and deletes only the sample-owned resource group.
