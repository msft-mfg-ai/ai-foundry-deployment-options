# Option: LiteLLM Gateway with Foundry Private CA Trust

This deployment option demonstrates Foundry's private CA trust support with multiple issuing CAs. LiteLLM and the sample MCP server are exposed on separate Azure Container Apps custom domains, each with a leaf certificate signed by an independent private root CA. Each public root is stored as its own versioned Key Vault secret and referenced separately by Foundry.

Foundry connects directly to the LiteLLM custom domain. No nginx trust proxy is deployed.

For the minimal changes needed to enable this on an existing certificate, Key Vault, and Foundry account, see [Add Private CA Trust to an Existing Foundry Account](EXISTING-FOUNDRY-PRIVATE-CA.md).

> This feature requires an allowlisted subscription and the preview APIs described in `spec.tmp`. The reference scenario uses `canadacentral`.

## Architecture

```text
Foundry account
  - user-assigned managed identity
  - trustedCertificates -> Key Vault secret version
  - account-level LiteLLM ModelGateway connections
  - projects + capability hosts
               |
               | HTTPS, private CA validated by Foundry
               v
LiteLLM custom domain                    MCP custom domain
  - private DNS -> ACA managed-environment private endpoint
  - independently signed leaf PFX        - independently signed leaf PFX
  - LiteLLM container: HTTP port 4000    - MCP container: HTTP port 3000

Key Vault
  - one PEM secret containing both public root CAs
  - Foundry identity: Key Vault Secrets User
```

Application Gateway continues to target LiteLLM's default `*.azurecontainerapps.io` hostname. That backend uses a Microsoft-trusted certificate and does not depend on Foundry's private CA configuration.

## Prerequisites

- Azure CLI and Azure Developer CLI (`azd`)
- `openssl` on `PATH`
- An allowlisted Azure subscription
- Deployment in a region that supports the preview feature (`canadacentral` in the supplied specification)
- Permission to create Foundry, Key Vault, networking, role-assignment, and Container Apps resources
- Control of public DNS for the LiteLLM and MCP custom domains

Configure the existing Azure OpenAI dependency:

```bash
azd env set OPENAI_API_BASE "https://<your-aoai>.openai.azure.com"
azd env set OPENAI_RESOURCE_ID "/subscriptions/.../resourceGroups/.../providers/Microsoft.CognitiveServices/accounts/<aoai>"
```

LiteLLM uses its Container App user-assigned managed identity for Azure OpenAI. The deployment grants that identity `Cognitive Services OpenAI User`; local authentication and API keys are not required.

## Deployment flow

ACA validates ownership before accepting a custom-domain binding. For a new ACA environment, its default hostname or custom-domain verification ID is not available until the environment exists, so bootstrap uses two `azd provision` runs.

### Phase 1: create LiteLLM infrastructure

```bash
azd env set LITELLM_DOMAIN ""
azd env set MCP_DOMAIN ""
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

Phase 1 creates networking, dependencies, the Foundry Key Vault, LiteLLM, its ACA environment, private endpoints, and Application Gateway. It does not create the Foundry account, projects, capability hosts, or ModelGateway connections. Foundry, networking, Storage, and AI Search remain in Canada Central; Cosmos DB is placed in East US 2 because this subscription currently has no Cosmos DB creation capacity in Canada Central.

Use each deployed app hostname and the ACA environment custom-domain verification ID to configure:

- `CNAME <LITELLM_DOMAIN> -> <LiteLLM default ACA hostname>`
- `CNAME <MCP_DOMAIN> -> <MCP default ACA hostname>`
- `TXT asuid.<LITELLM_DOMAIN> -> <ACA environment custom-domain verification ID>`
- `TXT asuid.<MCP_DOMAIN> -> <ACA environment custom-domain verification ID>`

### Phase 2: bind the domain and create Foundry

```bash
azd env set LITELLM_DOMAIN "litellm.your-domain.example.com"
azd env set MCP_DOMAIN "mcp.litellm.your-domain.example.com"
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

The preprovision hook generates:

- an independent self-signed root CA and leaf PFX for `LITELLM_DOMAIN`;
- an independent self-signed root CA and leaf PFX for `MCP_DOMAIN`;
- one PEM bundle containing both public roots for inspection or export.

The deployment then:

1. Binds each PFX to its corresponding LiteLLM or MCP ACA custom domain.
2. Stores the public roots as the `litellm-root-ca-pem` and `mcp-root-ca-pem` Key Vault secrets.
3. Grants the Foundry user-assigned identity `Key Vault Secrets User`.
4. Creates the Foundry account with one `trustedCertificates.certificates` entry pinned to each deployed secret version.
5. Creates projects and capability hosts after the trust configuration and RBAC assignment.
6. Creates dynamic and static ModelGateway connections targeting `https://<LITELLM_DOMAIN>`.
7. Creates a shared Foundry MCP connection targeting `https://<MCP_DOMAIN>/mcp/`.

If the required public DNS record is already configured for the ACA environment, phase 2 can be the only deployment run.

## Certificate lifecycle

Certificate material is reused while the corresponding azd environment values are present:

- `LITELLM_CERT_PFX_BASE64`
- `LITELLM_CERT_PFX_PASSWORD`
- `LITELLM_ROOT_CA_PEM_BASE64`
- `MCP_CERT_PFX_BASE64`
- `MCP_CERT_PFX_PASSWORD`
- `MCP_ROOT_CA_PEM_BASE64`
- `FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64`

To rotate both private CAs:

```bash
for value in \
  LITELLM_CERT_PFX_BASE64 \
  LITELLM_CERT_PFX_PASSWORD \
  LITELLM_ROOT_CA_PEM_BASE64 \
  MCP_CERT_PFX_BASE64 \
  MCP_CERT_PFX_PASSWORD \
  MCP_ROOT_CA_PEM_BASE64 \
  FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64; do
  azd env set "$value" ""
done

FORCE_REGENERATE=1 AZD_DISABLE_AGENT_DETECT=1 azd provision
```

To rotate only the MCP CA and rebuild the inspection bundle while preserving the LiteLLM CA:

```bash
FORCE_REGENERATE_MCP=1 AZD_DISABLE_AGENT_DETECT=1 azd provision
```

The deployment writes a new Key Vault secret version and updates the Foundry account reference. Per the preview feature contract, existing project capability hosts must then be deleted and recreated so they load the rotated CA.

## Deployed resources

### Networking and dependencies

- VNet and delegated subnets for Foundry agents, ACA, private endpoints, and Application Gateway
- Private DNS zones for ACA, PostgreSQL, Key Vault, Storage, Cosmos DB, and AI Search
- Foundry Storage, Cosmos DB, and AI Search dependencies

### LiteLLM

- Private ACA managed environment and private endpoint
- LiteLLM Container App
- Sample MCP Container App
- PostgreSQL Flexible Server
- LiteLLM Key Vault for application secrets
- Independently signed certificates bound to the LiteLLM and MCP custom domains

### Foundry Key Vault

- Private endpoint and private DNS
- `litellm-root-ca-pem` and `mcp-root-ca-pem` secrets, each containing one public root CA in PEM format
- `Key Vault Secrets User` role assignment for the Foundry account identity

### Foundry

- Foundry account configured with both versioned Key Vault secrets in `trustedCertificates`
- Configurable projects with capability hosts
- Dynamic and static account-level ModelGateway connections targeting the LiteLLM custom domain
- Shared account-level MCP connection targeting the MCP custom domain

### Public operator access

- Application Gateway with a public IP
- Backend target set to LiteLLM's default ACA hostname

## Outputs

| Output | Description |
|---|---|
| `FOUNDRY_PROJECTS_CONNECTION_STRINGS` | Project connection strings; empty in phase 1 |
| `FOUNDRY_PROJECT_NAMES` | Project names; empty in phase 1 |
| `LITELLM_DOMAIN` | Custom domain bound to LiteLLM |
| `LITELLM_FOUNDRY_TARGET_URL` | Direct HTTPS URL used by Foundry; empty in phase 1 |
| `LITELLM_INTERNAL_FQDN` | Default Microsoft-trusted ACA hostname |
| `MCP_DOMAIN` | Custom domain bound to the sample MCP server |
| `MCP_TOOL_URL` | Foundry MCP connection target, ending in `/mcp/` to avoid the server's redirect |
| `MCP_INTERNAL_FQDN` | Default Microsoft-trusted MCP ACA hostname |
| `LITELLM_UI_URL` | Application Gateway URL for the LiteLLM UI |
| `LITELLM_SWAGGER_URL` | Application Gateway URL for LiteLLM APIs |
| `PHASE` | Current bootstrap or trusted-Foundry phase |

## Troubleshooting

- **Custom-domain validation fails:** confirm the public CNAME or `asuid` TXT record has propagated, then rerun phase 2.
- **Foundry receives an unknown-authority error:** verify each Key Vault secret contains exactly one PEM certificate, `properties.trustedCertificates` contains the expected vault ID plus one name/version entry per root, and the Foundry identity has `Key Vault Secrets User`; recreate the project capability hosts and, for VNet-injected accounts, the account capability host after any trust change.
- **The custom domain does not resolve from Foundry:** verify the private DNS zone for `LITELLM_DOMAIN` is linked to the Foundry VNet and its apex A record points to the ACA managed-environment private endpoint IP.
- **Application Gateway returns a backend TLS error:** confirm its backend is the default LiteLLM ACA hostname, not the self-signed custom domain.
- **Phase 1 has no Foundry projects:** this is expected; set `LITELLM_DOMAIN`, complete public DNS validation, and run phase 2.
